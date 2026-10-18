import Foundation
import ShellKit

extension GitClient {

    /// git's `<repository>` argument as GitKit should see it: a
    /// configured remote's name stays as it is; anything else is a URL
    /// or path (an anonymous remote), authorized like a clone source
    /// first. A path resolves against the shell's working directory,
    /// since libgit2 would read it relative to the process's.
    func resolveRemoteOperand(_ remote: String) async throws -> String {
        // A URL isn't a valid remote name, so the lookup throws for it.
        if (try? await remoteExists(named: remote)) == true { return remote }
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
}
