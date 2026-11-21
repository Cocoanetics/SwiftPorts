@_spi(GitLFSKit) import SwiftGit

extension LFSClient {
    /// Share the push scanner's live remote advertisement across all ref updates.
    func pushUpdates(
        _ updates: [LFSRefUpdate], remote: String, all: Bool = false,
        dryRun: Bool, terminal: Bool, git: GitClient
    ) async throws -> LFSCommandResult {
        let remoteBranches = try? await git.remoteHeads(remote: remote)
        let locks = LFSLockVerifier(client: self, remote: remote, git: git)
        try await locks.verify(updates)
        var result = try await uploadObjects(
            for: updates, remote: remote, remoteBranches: remoteBranches, all: all,
            dryRun: dryRun, terminal: terminal, git: git, environment: LFSTransferEnvironment(), locks: locks)
        result.stderr = locks.stderr + result.stderr
        return result
    }
}
