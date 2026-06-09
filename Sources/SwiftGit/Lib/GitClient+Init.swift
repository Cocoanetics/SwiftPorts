import Foundation
import ShellKit
import libgit2

extension GitClient {

    /// Initialise a brand-new repository in `workingDirectory`. Creates
    /// the directory if it doesn't exist, then runs `git_repository_init`
    /// with the requested options. Mirrors `git init` semantics.
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
            try initRepositoryInner(
                bare: bare, initialBranch: initialBranch, reinit: reinit)
        }
        return workingDirectory
    }

    private func initRepositoryInner(
        bare: Bool, initialBranch: String?, reinit: Bool
    ) throws {
        Libgit2.ensureInitialized()
        try FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true)

        var opts = git_repository_init_options()
        try check(git_repository_init_init_options(
            &opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))

        var flags: UInt32 = UInt32(GIT_REPOSITORY_INIT_MKDIR.rawValue)
            | UInt32(GIT_REPOSITORY_INIT_MKPATH.rawValue)
        if bare { flags |= UInt32(GIT_REPOSITORY_INIT_BARE.rawValue) }
        if !reinit { flags |= UInt32(GIT_REPOSITORY_INIT_NO_REINIT.rawValue) }
        opts.flags = flags

        // libgit2 holds a non-owning pointer into `initial_head`; keep
        // the C string alive across the call by going through withCString.
        var repo: OpaquePointer?
        if let branch = initialBranch {
            try branch.withCString { ptr in
                opts.initial_head = ptr
                try check(git_repository_init_ext(&repo, workingDirectory.path, &opts))
            }
        } else {
            try check(git_repository_init_ext(&repo, workingDirectory.path, &opts))
        }
        git_repository_free(repo)
    }
}
