import Foundation
import ShellKit
import GitKit

extension GitClient {

    /// git's `<repository>` argument as GitKit should see it: a
    /// configured remote's name stays as it is; anything else is a URL
    /// or path (an anonymous remote) — see
    /// ``remoteForLibgit2(_:relativeTo:)``. git works from the top of the
    /// work tree, so a relative path is relative to there, wherever in
    /// the tree the shell is.
    func resolveRemoteOperand(_ remote: String) async throws -> String {
        // Not a path to the top of the work tree, as git sees it too.
        guard !remote.isEmpty else {
            throw Libgit2Error(code: -1, klass: 0, message: "bad repository ''")
        }
        // A URL isn't a valid remote name, so the lookup throws for it.
        if (try? await remoteExists(named: remote)) == true { return remote }
        let top = try await withRepository { try $0.toplevel() ?? $0.gitDir() }
        return try await remoteForLibgit2(remote, relativeTo: top)
    }

    /// A remote as git takes it — a URL, a scp-style `[user@]host:path`
    /// or a path — authorized like a clone source and ready for
    /// libgit2. URLs and scp-style remotes pass through exactly as typed;
    /// a relative path resolves against `directory`, else the shell's
    /// working directory, since libgit2 would read it relative to the
    /// process's.
    func remoteForLibgit2(_ remote: String, relativeTo directory: String? = nil) async throws -> String {
        if remote.contains("://") || Self.isSCPLike(remote) {
            if let url = URL(string: remote) {
                try await Shell.authorize(Self.authorizationURL(forRemote: url))
            }
            return remote
        }
        var spelling = remote
        if let directory, Self.isRelativePath(remote) {
            // Joined in the shell's spelling of the directory, so a
            // sandbox's path mapping applies to the result as it does to
            // any path a script names.
            var base = Shell.displayPath(for: directory)
            while base.count > 1, base.hasSuffix("/") { base.removeLast() }
            spelling = base.hasSuffix("/") ? base + remote : base + "/" + remote
        }
        let path = Shell.resolve(spelling)
        try await Shell.authorize(path)
        return path.path
    }

    /// Whether git reads `path` as relative (`is_absolute_path`): on
    /// Windows, a leading backslash (`\repo`, `\\server\share`) or a drive
    /// letter (`C:\repo`, `C:/repo`) roots it too.
    static func isRelativePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return false }
        #if os(Windows)
        if path.hasPrefix("\\") || path.dropFirst().first == ":" { return false }
        #endif
        return true
    }

    /// Record `remote`, as typed, as the upstream remote of each branch
    /// in `pushed`. GitKit records where it pushed — for a path, the
    /// resolved `location` — but git keeps the `<repository>` argument
    /// as given: `-u ../bare` records `../bare`, which still works once
    /// the repository and its remote move together.
    static func recordUpstreamRemote(
        _ remote: String, of pushed: [String], pushedTo location: String, in repository: Repository
    ) throws {
        let prefix = "refs/heads/"
        for refspec in pushed {
            let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
            let source = body.prefix { $0 != ":" }
            guard source.hasPrefix(prefix) else { continue }
            let key = "branch.\(source.dropFirst(prefix.count)).remote"
            if try repository.configGet(key) == location {
                try repository.configSet(key, remote)
            }
        }
    }

    /// git's rule for a scp-style `[user@]host:path` remote: no `://`,
    /// and a colon before any slash (`url_is_local_not_ssh`).
    static func isSCPLike(_ remote: String) -> Bool {
        guard !remote.contains("://"), let colon = remote.firstIndex(of: ":") else { return false }
        #if os(Windows)
        // `C:/repo` is a drive letter, not a host.
        if remote.distance(from: remote.startIndex, to: colon) == 1 { return false }
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
