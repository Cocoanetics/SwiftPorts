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

    package func withRepository<T>(at directory: URL, _ body: (Repository) throws -> T) throws -> T {
        try context.authorize(directory)
        let client = context.client(at: directory)
        let repository = try context.prepare {
            let repo = try Repository.open(at: directory)
            try client.prepare(repo)
            return repo
        }
        // Never put the host body in the include-authorization retry loop.
        let result = try body(repository)
        try context.checkCurrent()
        return result
    }

    package func createRepository<T>(
        at directory: URL, using create: () throws -> Void, _ body: (Repository) throws -> T
    ) throws -> T {
        try context.authorize(directory)
        // Creation (including clone's filter callbacks) inherits this operation.
        // It is a mutation: failure must propagate without calling it twice.
        try create()
        return try withRepository(at: directory, body)
    }
}
