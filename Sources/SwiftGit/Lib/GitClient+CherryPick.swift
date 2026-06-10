import Foundation
import ForgeKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` cherry-pick
// operations (`GitKit/Repository+CherryPick.swift`). Each call
// authorizes the working directory and isolates libgit2's global config
// view via `withRepository`, then hands off.
extension GitClient {

    /// Cherry-pick a single commit on top of HEAD — `git cherry-pick <commit>`.
    @discardableResult
    public func cherryPick(
        _ ref: String,
        author: GitSignature? = nil
    ) async throws -> CherryPickOutcome {
        let env = shellEnvironment()
        return try await withRepository {
            try $0.cherryPick(ref, author: author.core, env: env)
        }
    }

    /// Resume a paused cherry-pick after conflicts were resolved and staged.
    @discardableResult
    public func cherryPickContinue(
        author: GitSignature? = nil
    ) async throws -> CherryPickOutcome {
        let env = shellEnvironment()
        return try await withRepository {
            try $0.cherryPickContinue(author: author.core, env: env)
        }
    }

    /// `git cherry-pick --abort`: undo the in-progress cherry-pick.
    public func cherryPickAbort() async throws {
        try await withRepository { try $0.cherryPickAbort() }
    }

    /// `git cherry-pick --skip`: drop the conflicting commit and clean up.
    public func cherryPickSkip() async throws {
        try await withRepository { try $0.cherryPickSkip() }
    }
}
