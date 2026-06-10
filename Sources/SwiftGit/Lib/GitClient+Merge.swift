import Foundation
import ForgeKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` merge operation
// (`GitKit/Repository+Merge.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off. `pull` / `pullRebase` live here in
// full: they compose other sandbox-aware GitClient operations (fetch +
// merge / rebase) rather than wrapping a single Repository call.
extension GitClient {

    /// Run a real-git-style merge of `theirRef` into HEAD.
    public func merge(
        ref theirRef: String,
        fastForward: FastForwardMode = .auto,
        message: String? = nil,
        author: GitSignature? = nil
    ) async throws -> MergeOutcome {
        try await withRepository {
            try $0.merge(
                ref: theirRef,
                fastForward: fastForward,
                message: message,
                author: author.core)
        }
    }

    /// Fetch then merge — `git pull` semantics.
    ///
    /// `branch` defaults to the current branch's name. After the fetch,
    /// the remote-tracking ref `<remote>/<branch>` is the merge target.
    public func pull(
        remote: String = "origin",
        branch: String? = nil,
        fastForward: FastForwardMode = .auto,
        message: String? = nil,
        author: GitSignature? = nil
    ) async throws -> MergeOutcome {
        let local: String
        if let branch {
            local = branch
        } else {
            local = (try await currentBranch()) ?? "HEAD"
        }
        try await fetch(remote: remote, refspec: local)
        return try await merge(
            ref: "\(remote)/\(local)",
            fastForward: fastForward,
            message: message,
            author: author)
    }

    /// Fetch then rebase — `git pull --rebase` semantics. Replays the
    /// local branch's commits since their merge-base with
    /// `<remote>/<branch>` on top of the freshly-fetched ref.
    public func pullRebase(
        remote: String = "origin",
        branch: String? = nil,
        author: GitSignature? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RebaseOutcome {
        let local: String
        if let branch {
            local = branch
        } else {
            local = (try await currentBranch()) ?? "HEAD"
        }
        try await fetch(remote: remote, refspec: local)
        return try await rebase(
            upstream: "\(remote)/\(local)",
            author: author,
            progress: progress)
    }
}
