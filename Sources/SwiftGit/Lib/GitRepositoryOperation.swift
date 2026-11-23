import Foundation
import ForgeKit
import ShellKit

/// Package implementation of the public GitLFSKit native-operation boundary.
package struct GitRepositoryOperation {
    private let context: GitFilterOperationContext

    package static func run<T: Sendable>(
        credentials: CredentialProvider?, shell: Shell,
        _ body: (GitRepositoryOperation) throws -> T
    ) async throws -> T {
        // An async nested scope would wait on its own turn. Task-local inheritance
        // also rejects entry from callback bridge tasks before they enqueue.
        guard !insideOperation else { throw GitFilterOperationContext.Failure.unsupportedOperation }
        let cancellation = BlockingBridgeCancellation()
        return try await shell.withCurrent {
            try await $insideOperation.withValue(true) {
                try await withTaskCancellationHandler {
                    let client = GitClient(credentials: credentials)
                    return try await client.isolatedGated(retryIncludes: false, cancellation: cancellation) {
                        let context = try GitFilterOperationContext.capture()
                        return try body(GitRepositoryOperation(context: context))
                    }
                } onCancel: {
                    cancellation.cancel()
                }
            }
        }
    }

    @TaskLocal private static var insideOperation = false

    package func authorize(_ url: URL) throws {
        try context.authorize(url)
    }

    package var preparation: RepositoryPreparation {
        RepositoryPreparation { [context] repository in
            try context.prepareRepository(repository)
        }
    }

    package func withRepository<T>(at directory: URL, _ body: (Repository) throws -> T) throws -> T {
        try context.checkCurrent()
        try context.authorize(directory)
        let result = try scoped {
            let repository = try context.rethrowDenial {
                let repo = try Repository.open(at: directory, includePolicy: context.includePolicy)
                try context.prepareRepository(repo)
                return repo
            }
            // Never replay the host body across include authorization.
            return try context.rethrowDenial { try body(repository) }
        }
        try context.checkCurrent()
        return result
    }

    package func createRepository<T>(
        at directory: URL,
        using create: (RepositoryPreparation) throws -> Repository,
        _ body: (Repository) throws -> T
    ) throws -> T {
        try context.checkCurrent()
        try context.authorize(directory)
        weak var preparedHandle: Repository?
        let scopedPreparation = RepositoryPreparation { [context] repository in
            try context.prepareRepository(repository)
            preparedHandle = repository
        }
        let repository = try context.rethrowDenial {
            let created = try create(scopedPreparation)
            if preparedHandle !== created {
                try context.prepareRepository(created)
            }
            return created
        }
        let result = try scoped { try context.rethrowDenial { try body(repository) } }
        try context.checkCurrent()
        return result
    }

    /// Gives the operation's configuration to the repositories libgit2 opens
    /// on this thread for `body`, including each submodule's during status
    /// and diff. Creation uses `RepositoryPreparation` and can inherit an
    /// enclosing scope; GitKit rolls back initialization if an include is refused.
    private func scoped<T>(_ body: () throws -> T) throws -> T {
        try context.rethrowDenial {
            try Repository.withOperationConfiguration(context.operationConfiguration, body)
        }
    }
}
