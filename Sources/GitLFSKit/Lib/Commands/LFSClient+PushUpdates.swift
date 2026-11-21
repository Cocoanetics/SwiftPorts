@_spi(GitLFSKit) import SwiftGit

extension LFSClient {
    /// Share the push scanner's live remote advertisement across all ref updates.
    func pushUpdates(
        _ updates: [LFSRefUpdate], remote: String, all: Bool = false,
        dryRun: Bool, terminal: Bool, git: GitClient
    ) async throws -> LFSCommandResult {
        let remoteBranches = try? await git.remoteHeads(remote: remote)
        return try await uploadObjects(for: updates, remote: remote, remoteBranches: remoteBranches,
                                       all: all, dryRun: dryRun, terminal: terminal, git: git)
    }
}
