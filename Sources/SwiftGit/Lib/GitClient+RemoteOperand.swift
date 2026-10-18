import Foundation
import ShellKit
import GitKit

extension GitClient {

    /// git's `<repository>` argument as GitKit should see it: a
    /// configured remote's name stays as it is; anything else is a URL
    /// or path (an anonymous remote) — see ``remoteForLibgit2(_:)``.
    func resolveRemoteOperand(_ remote: String) async throws -> String {
        // A URL isn't a valid remote name, so the lookup throws for it.
        if (try? await remoteExists(named: remote)) == true { return remote }
        return try await remoteForLibgit2(remote)
    }

    /// A remote as git takes it — a URL, a scp-style `[user@]host:path`
    /// or a path — authorized like a clone source and ready for
    /// libgit2. URLs and scp-style remotes pass through exactly as typed;
    /// a path resolves against the shell's working directory, since
    /// libgit2 would read it relative to the process's.
    func remoteForLibgit2(_ remote: String) async throws -> String {
        if remote.contains("://") || Self.isSCPLike(remote) {
            if let url = URL(string: remote) {
                try await Shell.authorize(Self.authorizationURL(forRemote: url))
            }
            return remote
        }
        let path = Shell.resolve(remote)
        try await Shell.authorize(path)
        return path.path
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

    /// The directory `git clone` names after a remote: its last path
    /// component without a trailing `.git` (git's "humanish" part), so
    /// `git@host:org/repo.git` clones into `repo`.
    public static func humanishName(of remote: String) -> String {
        var name = Substring(remote)
        while name.hasSuffix("/") { name = name.dropLast() }
        if name.hasSuffix(".git") { name = name.dropLast(4) }
        while name.hasSuffix("/") { name = name.dropLast() }
        if let separator = name.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            name = name[name.index(after: separator)...]
        }
        return name.isEmpty ? "repo" : String(name)
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
        let destination = directory
            ?? workingDirectory.appendingPathComponent(Self.humanishName(of: remote))
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
