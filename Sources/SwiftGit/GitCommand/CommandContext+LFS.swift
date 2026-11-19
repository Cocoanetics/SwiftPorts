import GitLFSKit

extension CommandContext {
    /// An LFS client rooted like ``gitClient(quiet:)``. Credentials are
    /// ``envCredentialProvider()``, the same callback a `GitClient` gets,
    /// so LFS never shells out to `git credential`.
    static func lfsClient(quiet: Bool = false) async -> LFSClient {
        await LFSClient(git: gitClient(quiet: quiet), credentials: envCredentialProvider())
    }
}
