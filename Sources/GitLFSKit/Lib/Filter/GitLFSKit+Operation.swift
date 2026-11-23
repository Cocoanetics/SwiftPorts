import Foundation
import ShellKit
import SwiftGit

extension GitLFSKit {
    /// Run synchronous native GitKit operations with scoped LFS credentials,
    /// configuration and sandbox isolation. No repository has to exist at entry.
    /// The body runs once and must not escape repositories or start async git work.
    public static func withOperation<T: Sendable>(
        credentials: CredentialProvider? = nil, shell: Shell = .current,
        _ body: (Operation) throws -> T
    ) async throws -> T {
        try await GitRepositoryOperation.run(credentials: credentials, shell: shell) {
            try body(Operation(operation: $0))
        }
    }
}
