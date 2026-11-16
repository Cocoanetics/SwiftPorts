import Foundation
import ForgeKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` rebase operations
// (`GitKit/Repository+Rebase.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// Replay the current branch's commits on top of `upstream` (or
    /// `onto`) — `git rebase <upstream> [--onto <onto>]`.
    public func rebase(
        upstream upstreamSpec: String,
        onto ontoSpec: String? = nil,
        author: GitSignature? = nil,
        sign: SignMode = .config,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RebaseOutcome {
        let env = shellEnvironment()
        return try await withRepository {
            try $0.rebase(
                upstream: upstreamSpec, onto: ontoSpec,
                author: author.core, progress: progress, env: env, sign: try resolvedCommitSignMode(sign))
        }
    }

    /// Continue a rebase paused on a conflict after the working tree
    /// has been resolved and staged. `.config` keeps the signing the
    /// rebase was started with (GitKit kept it in `gpg_sign_opt`, as git
    /// does), else `commit.gpgsign`.
    public func rebaseContinue(
        author: GitSignature? = nil,
        sign: SignMode = .config,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RebaseOutcome {
        let env = shellEnvironment()
        return try await withRepository {
            try $0.rebaseContinue(author: author.core, progress: progress, env: env, sign: sign)
        }
    }

    /// Skip the conflicting commit and resume the rebase, signing as
    /// ``rebaseContinue(author:sign:progress:)`` does.
    public func rebaseSkip(
        author: GitSignature? = nil,
        sign: SignMode = .config,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RebaseOutcome {
        let env = shellEnvironment()
        return try await withRepository {
            try $0.rebaseSkip(author: author.core, progress: progress, env: env, sign: sign)
        }
    }

    /// Wipe an in-progress rebase, restoring the working tree + HEAD.
    public func rebaseAbort() async throws {
        try await withRepository { try $0.rebaseAbort() }
    }
}
