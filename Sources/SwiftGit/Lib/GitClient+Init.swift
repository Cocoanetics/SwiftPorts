import Foundation
import ShellKit
import GitKit
import CGitKit

extension GitClient {

    /// Initialise a brand-new repository in `workingDirectory`. Creates
    /// the directory if it doesn't exist, then runs `git_repository_init`
    /// with the requested options. Mirrors `git init` semantics.
    ///
    /// Sandbox-aware face over ``GitKit/Repository/initialize(at:bare:initialBranch:reinit:)``.
    ///
    /// - Parameters:
    ///   - bare: Create a bare repo (`init --bare`) — no working tree.
    ///   - initialBranch: Override the default branch name (real git
    ///     uses `init.defaultBranch`, falling back to `master`). Pass
    ///     e.g. `"main"` to mirror `git init -b main`.
    ///   - reinit: If `true`, succeed silently when the directory is
    ///     already a repo. If `false` (the default), libgit2 will error.
    @discardableResult
    public func initRepository(
        bare: Bool = false,
        initialBranch: String? = nil,
        reinit: Bool = false
    ) async throws -> URL {
        try await Shell.authorize(workingDirectory)
        // Tier-2 (#18): apply env→option bridge before init so the
        // freshly-created repo's seeded config is loaded against the
        // sandbox's view, not the host's.
        try await isolated {
            // libgit2 reads `init.defaultBranch` from its own default config,
            // which the environment's GIT_CONFIG_* never reach: read it here.
            let branch = try initialBranch ?? Self.environmentDefaultBranch()
            _ = try Repository.initialize(
                at: workingDirectory,
                bare: bare, initialBranch: branch, reinit: reinit)
        }
        return workingDirectory
    }

    /// `init.defaultBranch` as the environment's config sets it, `nil` when
    /// it doesn't (libgit2's own lookup then stands).
    private static func environmentDefaultBranch() throws -> String? {
        guard Libgit2Sandboxing.shared.environment.needsInstall else { return nil }
        var repo: OpaquePointer?
        var config: OpaquePointer?
        var value: UnsafePointer<CChar>?
        defer {
            git_config_free(config)
            git_repository_free(repo)
        }
        try check(git_repository_new(&repo))
        try installEnvironmentConfig(intoRepository: repo)
        try check(git_repository_config_snapshot(&config, repo))
        guard git_config_get_string(&value, config, "init.defaultbranch") == 0 else { return nil }
        return value.map { String(cString: $0) }
    }
}
