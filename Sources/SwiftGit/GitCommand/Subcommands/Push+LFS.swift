import ForgeKit
import GitLFSKit
import ShellKit
import SwiftGit

extension Push {
    /// git-lfs's pre-push hook refused the push; its output has been
    /// written.
    struct PrePushRefused: Error {}

    /// The work of the pre-push hook git would run, when it is git-lfs's
    /// (``GitLFSKit/Hook/lfsPrePush(_:)``), done in-process instead of
    /// running the script: git-lfs 3.7.1's `pre-push <remote> <url>` over
    /// the updates the push is about to send, its stdout and stderr
    /// passed on as git passes a hook's. `nil` when git would run no such hook.
    static func lfsPrePush(
        client: SwiftGit.GitClient, remote: String
    ) async throws -> (@Sendable ([PushUpdate], SwiftGit.GitClient) async throws -> Void)? {
        guard await Hook.lfsPrePush(client) != nil else { return nil }
        let url = try await client.displayName(ofRemote: remote)
        let credentials = CommandContext.envCredentialProvider()
        let terminal = TTY.isStderrTTY
        return { updates, git in
            // Every git read the upload makes goes through `git`, which
            // runs in the push's isolation while the push waits.
            let lfs = await LFSClient(git: git, credentials: credentials)
            let result = try await PrePushOptions().run(
                [remote, url],
                updates: updates.map {
                    LFSRefUpdate(localRef: $0.localRef, localOID: $0.localOID,
                                 remoteRef: $0.remoteRef, remoteOID: $0.remoteOID)
                },
                client: lfs, git: git, terminal: terminal)
            Shell.current.stdout.write(result.stdout)
            Shell.current.stderr.write(result.stderr)
            if result.status != 0 { throw PrePushRefused() }
        }
    }
}
