import Foundation
import Testing
import ShellKit
@testable import SwiftGit

@Suite("Filter operation context lifetime")
struct GitFilterOperationContextTests {
    @Test("capture is scoped to the operation and revoked on thrown return")
    func revokedOnFailure() async throws {
        let shell = Shell()
        let client = GitClient()
        #expect(!GitFilters.isRegistered("lfs"))
        #expect(throws: GitFilterOperationContext.Failure.noOperation) {
            _ = try GitFilterOperationContext.capture()
        }
        let context = GitFilterOperationContext(
            shell: shell, credentials: nil, environment: .none, gate: ConfigIncludeGate(enforcing: false))
        #expect(throws: GitFilterOperationContext.Failure.unsupportedOperation) {
            try context.run {
                #expect(try GitFilterOperationContext.capture() === context)
                throw GitFilterOperationContext.Failure.unsupportedOperation
            }
        }
        #expect(throws: GitFilterOperationContext.Failure.noOperation) {
            _ = try GitFilterOperationContext.capture()
        }
        await #expect(throws: GitFilterOperationContext.Failure.expired) {
            try await context.withRepository(client) { _ in Issue.record("expired lease opened a repository") }
        }
    }
}
