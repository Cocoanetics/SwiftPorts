import Foundation
import ShellKit
import GitKit

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
        try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
            _ = try Repository.initialize(
                at: workingDirectory,
                bare: bare, initialBranch: initialBranch, reinit: reinit)
        }
        return workingDirectory
    }
}
