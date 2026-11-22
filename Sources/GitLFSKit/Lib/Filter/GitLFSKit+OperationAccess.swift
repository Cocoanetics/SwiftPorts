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

        /// Open and prepare a primary, linked-worktree or submodule repository.
        /// Configuration preparation may retry; `body` is called only once.
        public func withRepository<T>(at directory: URL, _ body: (Repository) throws -> T) throws -> T {
            try operation.withRepository(at: directory, body)
        }

        /// Create a repository using native GitKit (initialize or clone), then
        /// reopen and prepare its handle before invoking `body`. Both closures
        /// run at most once. Clone's filters use their own source repository's
        /// metadata and this operation's credentials, including during creation.
        /// Authorize the clone source separately before entering `create`.
        public func createRepository<T>(
            at directory: URL, using create: () throws -> Void, _ body: (Repository) throws -> T
        ) throws -> T {
            try operation.createRepository(at: directory, using: create, body)
        }
    }
}
