import Foundation
import CGitKit
import ShellKit
import GitKit

extension GitClient {

    /// Which way a remote is used: a push goes to its push URL.
    enum RemoteUse { case fetch, push }

    /// git's `<repository>` argument and where to connect for it.
    struct RemoteConnection: Equatable {
        /// The remote as GitKit names it: a configured remote's name, or
        /// the URL or path as typed, which is what git shows in its
        /// output and records for `-u`.
        let remote: String
        /// Where libgit2 connects, exactly: the location authorized.
        let location: String
    }

    /// git's `<repository>` argument as GitKit should see it: a
    /// configured remote's name, or else a URL or path as typed (an
    /// anonymous remote), along with where libgit2 is to connect for
    /// `use`, which is what's authorized. git works from the top of the
    /// work tree, so a relative path — typed, or a configured URL or push
    /// URL — is relative to there, wherever in the tree the shell is,
    /// and libgit2, which would read it against the process's directory,
    /// gets it resolved.
    func resolveRemoteOperand(_ remote: String, for use: RemoteUse = .fetch) async throws -> RemoteConnection {
        // Not a path to the top of the work tree, as git sees it too.
        guard !remote.isEmpty else {
            throw Libgit2Error(code: -1, klass: 0, message: "bad repository ''")
        }
        #if os(Windows)
        // A fetch or push takes `C://x` for a URL with scheme `C`
        // (transport_get checks is_url before any path); only a clone
        // looks on disk first.
        if Self.hasDrivePrefix(remote) { try Self.requireTransport(for: remote) }
        #endif
        let top = try await withRepository { try $0.toplevel() ?? $0.gitDir() }
        // A URL isn't a valid remote name, so the lookup throws for it.
        if (try? await remoteExists(named: remote)) == true {
            let configured = try await withRepository { _ in
                try Self.configuredLocation(of: remote, for: use, in: workingDirectory)
            }
            #if os(Windows)
            if Self.hasDrivePrefix(configured) { try Self.requireTransport(for: configured) }
            #endif
            let location = Self.connectionLocation(of: configured, relativeTo: top)
            try await Self.authorize(location: location)
            return RemoteConnection(remote: remote, location: location)
        }
        let rewritten = try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
            try Self.effectiveLocation(of: remote, for: use, in: workingDirectory)
        }
        let location = Self.connectionLocation(of: rewritten, relativeTo: top)
        try await Self.authorize(location: location)
        return RemoteConnection(remote: remote, location: location)
    }

    /// Where to connect for `location`, a URL or path as git reads it
    /// (after `insteadOf`): a URL as it is; a path resolved in the
    /// shell's spelling, so a sandbox's path mapping applies to it as to
    /// any path a script names, and a relative one against `directory`
    /// (else the shell's working directory) — the top of the work tree,
    /// where git reads it.
    static func connectionLocation(of location: String, relativeTo directory: String?) -> String {
        guard !isURLOrSCPLike(location) else { return location }
        var spelling = location
        if let directory, isRelativePath(location) {
            var base = Shell.displayPath(for: directory)
            while base.count > 1, base.hasSuffix("/") { base.removeLast() }
            spelling = base.hasSuffix("/") ? base + location : base + "/" + location
        }
        return Shell.resolve(spelling).path
    }

    /// Where libgit2 connects for configured remote `name`: its URL
    /// (after `url.<base>.insteadOf`), or for a push its push URL when it
    /// has one, as `git_remote__urlfordirection` picks it. GitKit keeps
    /// its repository handle to itself, so this opens its own.
    static func configuredLocation(of name: String, for use: RemoteUse, in directory: URL) throws -> String {
        var repo: OpaquePointer?
        var remote: OpaquePointer?
        defer {
            git_remote_free(remote)
            git_repository_free(repo)
        }
        try check(git_repository_open_ext(&repo, directory.path, 0, nil))
        try check(git_remote_lookup(&remote, repo, name))
        let pushURL = use == .push ? git_remote_pushurl(remote) : nil
        guard let location = pushURL ?? git_remote_url(remote) else {
            throw Libgit2Error(code: -1, klass: 0, message: "remote '\(name)' has no URL")
        }
        return String(cString: location)
    }

    /// Where libgit2 connects for `spelling`, a URL or path as it gets it:
    /// after `url.<base>.insteadOf` (and `pushInsteadOf` for a push),
    /// through an anonymous remote of the repository at `directory`, or
    /// of the default configuration without one, as for a clone.
    static func effectiveLocation(of spelling: String, for use: RemoteUse, in directory: URL?) throws -> String {
        var repo: OpaquePointer?
        var remote: OpaquePointer?
        defer {
            git_remote_free(remote)
            git_repository_free(repo)
        }
        if let directory {
            try check(git_repository_open_ext(&repo, directory.path, 0, nil))
            try check(git_remote_create_anonymous(&remote, repo, spelling))
        } else {
            var options = git_remote_create_options()
            try check(git_remote_create_options_init(&options, UInt32(GIT_REMOTE_CREATE_OPTIONS_VERSION)))
            try check(git_remote_create_with_opts(&remote, spelling, &options))
        }
        let pushURL = use == .push ? git_remote_pushurl(remote) : nil
        return (pushURL ?? git_remote_url(remote)).map { String(cString: $0) } ?? spelling
    }

    /// Authorize where libgit2 connects: a URL or scp-style remote by its
    /// host, refusing one git has no transport for; a path as the process
    /// reads it.
    static func authorize(location: String) async throws {
        if isURLOrSCPLike(location) {
            try requireTransport(for: location)
            try await authorizeURL(location)
        } else {
            try await Shell.authorize(URL(fileURLWithPath: location))
        }
    }

    /// Authorize a URL or scp-style remote by the host it reaches. One
    /// `URL(string:)` can't read as typed is read percent-encoded, so a
    /// sandbox still sees its host; one that still can't be read is
    /// refused under a sandbox rather than let through.
    static func authorizeURL(_ remote: String) async throws {
        let url = URL(string: remote)
            ?? remote.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let url else {
            guard Shell.current.sandbox == nil else {
                throw Sandbox.Denial(
                    url: URL(fileURLWithPath: Shell.unmappedPathSentinel),
                    reason: "cannot tell which host '\(remote)' reaches")
            }
            return
        }
        try await Shell.authorize(authorizationURL(forRemote: url))
    }

    /// A remote as git takes it — a URL, a scp-style `[user@]host:path`
    /// or a path — ready for libgit2, and authorized by where libgit2 will
    /// connect. git first rewrites the remote as typed by
    /// `url.<base>.insteadOf` (from the repository at `repository`, or
    /// the default configuration for a clone), a relative path included,
    /// and only then reads it as a URL or a path. A URL goes to libgit2
    /// as typed, to be rewritten the same way; a path resolves against
    /// `directory`, else the shell's working directory, since libgit2
    /// would read a relative one against the process's.
    func remoteForLibgit2(
        _ remote: String, relativeTo directory: String? = nil,
        for use: RemoteUse = .fetch, in repository: URL? = nil
    ) async throws -> String {
        func location(of spelling: String) throws -> String {
            try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
                try Self.effectiveLocation(of: spelling, for: use, in: repository)
            }
        }
        let rewritten = try location(of: remote)
        let spelling = Self.isURLOrSCPLike(rewritten)
            ? remote : Self.connectionLocation(of: rewritten, relativeTo: directory)
        try await Self.authorize(location: location(of: spelling))
        return spelling
    }

    /// Whether git reads `path` as relative (`is_absolute_path`): on
    /// Windows, a leading backslash (`\repo`, `\\server\share`) or a drive
    /// letter (`C:\repo`, `C:/repo`) roots it too.
    static func isRelativePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return false }
        #if os(Windows)
        if path.hasPrefix("\\") || hasDrivePrefix(path) { return false }
        #endif
        return true
    }

    #if os(Windows)
    /// git's `has_dos_drive_prefix`: one character, then a colon. Not
    /// only a letter: `subst` can make a drive of `1:` or `ä:`.
    static func hasDrivePrefix(_ path: String) -> Bool {
        !path.unicodeScalars.isEmpty && path.unicodeScalars.dropFirst().first == ":"
    }
    #endif

    /// The schemes git reaches a remote through: its own transports, and
    /// the helpers it ships (`transport_get`).
    static let transportSchemes: Set<String> = [
        "file", "git", "ssh", "git+ssh", "ssh+git", "http", "https", "ftp", "ftps"
    ]

    /// `remote`'s scheme when git reads it as a URL (`is_url`): an
    /// alphanumeric, then alphanumerics, `+`, `.` or `-`, up to the first
    /// colon, which `//` follows.
    static func urlScheme(of remote: String) -> String? {
        guard let colon = remote.firstIndex(of: ":"), remote[colon...].hasPrefix("://") else { return nil }
        let scheme = remote[..<colon]
        func isSchemeCharacter(_ character: Character, first: Bool) -> Bool {
            guard character.isASCII else { return false }
            return character.isLetter || character.isNumber || (!first && "+.-".contains(character))
        }
        guard let head = scheme.first, isSchemeCharacter(head, first: true),
              scheme.dropFirst().allSatisfy({ isSchemeCharacter($0, first: false) })
        else { return nil }
        return String(scheme)
    }

    /// Refuses, as git does, a remote no transport handles: a URL whose
    /// scheme has no helper, or `://` after something that isn't a scheme
    /// at all, which git's own transports take and find no protocol for
    /// (`get_protocol`). libgit2 would take either for SSH.
    static func requireTransport(for remote: String) throws {
        guard let separator = remote.range(of: "://") else { return }
        guard let scheme = urlScheme(of: remote) else {
            throw UnsupportedTransportError.protocolNotSupported(String(remote[..<separator.lowerBound]))
        }
        guard transportSchemes.contains(scheme) else {
            throw UnsupportedTransportError.noHelper(scheme: scheme)
        }
    }

    /// Whether `remote` reaches a host — a URL or a scp-style
    /// `[user@]host:path` — rather than naming a path. On Windows a drive
    /// letter makes it a path even with `//` after the colon
    /// (`C://repos/r.git`), which libgit2 opens as a local directory and
    /// `git clone` finds on disk.
    public static func isURLOrSCPLike(_ remote: String) -> Bool {
        #if os(Windows)
        if hasDrivePrefix(remote) { return false }
        #endif
        return remote.contains("://") || isSCPLike(remote)
    }

    /// git's rule for a scp-style `[user@]host:path` remote: no `://`,
    /// and a colon before any slash (`url_is_local_not_ssh`).
    public static func isSCPLike(_ remote: String) -> Bool {
        guard !remote.contains("://"), let colon = remote.firstIndex(of: ":") else { return false }
        #if os(Windows)
        // `C:/repo` is a drive letter, not a host; `1:repo.git` is a host.
        if hasDrivePrefix(remote) { return false }
        #endif
        return !remote[..<colon].contains("/")
    }

    /// The directory `git clone` names after a remote, git's "humanish"
    /// part (`git_url_basename`): the last component of the URL or path
    /// without a trailing `.git` or `/.git`, so `git@host:org/repo.git`
    /// clones into `repo`. A remote naming only a host gives the host,
    /// without credentials or port (`ssh://me@host:2222` gives `host`),
    /// and control characters and runs of whitespace become one space.
    /// `nil` when git can't guess a name (`host:.git`).
    public static func humanishName(of remote: String) -> String? {
        let bytes = Array(remote.utf8)
        func isSeparator(_ byte: UInt8) -> Bool {
            #if os(Windows)
            return byte == UInt8(ascii: "/") || byte == UInt8(ascii: "\\")
            #else
            return byte == UInt8(ascii: "/")
            #endif
        }
        // git's `isspace`: space, tab, newline and carriage return.
        func isSpace(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0A, 0x0D].contains(byte) }

        // Past the scheme, and past credentials: everything up to the
        // last `@` before the first separator.
        var start = 0, end = bytes.count
        let scheme = Array("://".utf8)
        if let at = bytes.indices.first(where: { bytes[$0...].starts(with: scheme) }) {
            start = at + scheme.count
        }
        var index = start
        while index < end, !isSeparator(bytes[index]) {
            if bytes[index] == UInt8(ascii: "@") { start = index + 1 }
            index += 1
        }
        // No trailing separators or spaces, and no `/.git`.
        while start < end, isSeparator(bytes[end - 1]) || isSpace(bytes[end - 1]) { end -= 1 }
        if end - start > 5, isSeparator(bytes[end - 5]), bytes[(end - 4)..<end].elementsEqual(".git".utf8) {
            end -= 5
            while start < end, isSeparator(bytes[end - 1]) { end -= 1 }
        }
        // A host without a path (a colon, no slash) loses its port.
        let rest = bytes[start..<end]
        if !rest.contains(UInt8(ascii: "/")), rest.contains(UInt8(ascii: ":")) {
            var digits = end
            while start < digits, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[digits - 1]) {
                digits -= 1
            }
            if start < digits, bytes[digits - 1] == UInt8(ascii: ":") { end = digits - 1 }
        }
        // The last component; a colon ends one too (`host:repo.git`).
        var component = end
        while start < component, !isSeparator(bytes[component - 1]), bytes[component - 1] != UInt8(ascii: ":") {
            component -= 1
        }
        var name = bytes[component..<end]
        if name.count >= 4, name.suffix(4).elementsEqual(".git".utf8) { name = name.dropLast(4) }
        guard !name.isEmpty, !name.elementsEqual("/".utf8) else { return nil }

        var cleaned: [UInt8] = []
        var afterSpace = true
        for byte in name {
            let byte = byte < 0x20 ? 0x20 : byte
            if isSpace(byte) {
                if afterSpace { continue }
                afterSpace = true
            } else {
                afterSpace = false
            }
            cleaned.append(byte)
        }
        if afterSpace, !cleaned.isEmpty { cleaned.removeLast() }
        return cleaned.isEmpty ? nil : String(decoding: cleaned, as: UTF8.self)
    }

    /// Clone `remote` — a URL, a scp-style `[user@]host:path` or a path,
    /// exactly as `git clone` takes it — into `directory`, or into the
    /// remote's ``humanishName(of:)`` in the working directory. Unlike
    /// ``clone(url:directory:depth:singleBranch:branch:)``, the remote
    /// reaches libgit2 as typed: a `URL` can't always hold a scp-style
    /// remote exactly.
    public func clone(
        remote: String,
        directory: URL?,
        depth: Int? = nil,
        singleBranch: Bool = false,
        branch: String? = nil
    ) async throws {
        let source = try await remoteForLibgit2(remote)
        guard let destination = directory
            ?? Self.humanishName(of: remote).map({ workingDirectory.appendingPathComponent($0) })
        else {
            throw Libgit2Error(
                code: -1, klass: 0,
                message: "No directory name could be guessed.\nPlease specify a directory on the command line")
        }
        try await Shell.authorize(destination)
        let progress = shellProgressSink()
        try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
            _ = try Repository.clone(
                fromRemote: source, to: destination,
                depth: depth, singleBranch: singleBranch, branch: branch,
                credentials: credentials, progress: progress)
        }
    }

    /// `git remote add <name> <remote>`, storing the remote exactly as
    /// typed.
    public func addRemote(name: String, remote: String) async throws {
        try await withRepository { try $0.addRemote(name: name, remote: remote) }
    }

    /// `git remote set-url <name> <remote>`, storing the remote exactly
    /// as typed.
    public func remoteSetURL(name: String, remote: String) async throws {
        try await withRepository { try $0.remoteSetURL(name: name, remote: remote) }
    }
}

/// A remote git has no transport for.
public enum UnsupportedTransportError: Error, LocalizedError, Equatable {
    /// A URL whose scheme has no `git-remote-<scheme>` helper.
    case noHelper(scheme: String)
    /// `://` after something that isn't a URL scheme.
    case protocolNotSupported(String)

    /// What git prints, `fatal:` and all.
    public var lines: [String] {
        switch self {
        case .noHelper(let scheme):
            ["git: 'remote-\(scheme)' is not a git command. See 'git --help'.",
             "fatal: remote helper '\(scheme)' aborted session"]
        case .protocolNotSupported(let name):
            ["fatal: protocol '\(name)' is not supported"]
        }
    }

    public var errorDescription: String? { lines.joined(separator: "\n") }
}
