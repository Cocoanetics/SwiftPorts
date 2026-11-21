import Foundation
import ShellKit

extension LFSEndpointFinder {
    /// `cfg.SetValidRemote` / `SetValidPushRemote`, including the local-path retry.
    func validateRemote(_ remote: String, argument: String? = nil) async throws {
        if remoteNames.contains(remote) || Self.validRemoteURL(remote) { return }
        let path = URL(fileURLWithPath: remote, relativeTo: client.workingDirectory).standardizedFileURL
        try await Shell.authorize(path)
        try await Shell.authorize(path.appendingPathComponent(".git"))
        let rewritten = LFSEndpointDerivation.rewriteLocalPath(remote, base: client.workingDirectory.path)
        if Self.validRemoteURL(rewritten) { return }
        throw LFSFailure("Invalid remote name \((argument ?? remote).goQuoted): "
            + "invalid remote name: \(rewritten.goQuoted)")
    }

    static func validRemoteURL(_ remote: String) -> Bool {
        guard let scheme = LFSURL.scheme(of: remote) else { return remote.contains(":") }
        return ["ssh", "http", "https", "git", "file"].contains(scheme)
    }
}
