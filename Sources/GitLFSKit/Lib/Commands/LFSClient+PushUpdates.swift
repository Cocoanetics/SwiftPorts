@_spi(GitLFSKit) import SwiftGit

extension LFSClient {
    /// Share the push scanner's live remote advertisement across all ref updates.
    func pushUpdates(
        _ updates: [LFSRefUpdate], remote: String, all: Bool = false,
        dryRun: Bool, terminal: Bool, git: GitClient
    ) async throws -> LFSCommandResult {
        let url = finder.aliases.replace(finder.gitRemoteURL(remote, upload: false), upload: false)
        var headers: [String] = []
        for header in finder.urlConfig.getAll(prefix: "http", url: url, key: "extraHeader") {
            // git's http.extraHeader is cumulative; an empty value resets it.
            if header.isEmpty { headers.removeAll() }
            else { headers.append(header) }
        }
        let remoteBranches = try? await git.remoteHeads(remote: remote, httpHeaders: headers)
        let locks = LFSLockVerifier(client: self, remote: remote, git: git)
        try await locks.verify(updates)
        var result = try await uploadObjects(
            for: updates, remote: remote, remoteBranches: remoteBranches, all: all,
            dryRun: dryRun, terminal: terminal, git: git, environment: LFSTransferEnvironment(), locks: locks)
        result.stderr = locks.stderr + result.stderr
        return result
    }
}
