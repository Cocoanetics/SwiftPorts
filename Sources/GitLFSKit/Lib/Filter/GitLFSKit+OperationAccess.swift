import Foundation
import SwiftGit

extension GitLFSKit {
    /// Repository access confined to the synchronous `withOperation` body.
    /// Each handle receives the same effective environment, include gate and signer.
    public struct Operation {
        let operation: GitRepositoryOperation

        /// Authorize an additional worktree destination or actual connection URL
        /// before passing it to native GitKit. Relative remotes must be resolved by
        /// the host, including push URLs and URL rewriting.
        public func authorize(_ url: URL) throws {
            try operation.authorize(url)
        }

        /// Creation-time preparation for native GitKit APIs that accept
        /// `RepositoryPreparation` (such as `Repository.clone(..., preparation:)`
        /// and `Repository.worktreeAdd(..., preparation:)`). Installs this
        /// operation's include policy, signer and effective configuration levels
        /// before the first checkout. Revoked when `withOperation` returns.
        public var preparation: RepositoryPreparation {
            operation.preparation
        }

        /// Open and prepare a primary, linked-worktree or submodule repository.
        /// Include authorization happens on demand; `body` runs at most once.
        public func withRepository<T>(at directory: URL, _ body: (Repository) throws -> T) throws -> T {
            try operation.withRepository(at: directory, body)
        }

        /// Create a repository using native GitKit (such as `Repository.clone`
        /// with the supplied `RepositoryPreparation`, or `Repository.initialize`),
        /// then invoke `body` with the prepared handle. Both closures run at most
        /// once; a handle not already prepared via `RepositoryPreparation` is
        /// prepared before `body`. Authorize any clone source separately before
        /// entering `create`.
        public func createRepository<T>(
            at directory: URL,
            using create: (RepositoryPreparation) throws -> Repository,
            _ body: (Repository) throws -> T
        ) throws -> T {
            try operation.createRepository(at: directory, using: create, body)
        }
    }
}
