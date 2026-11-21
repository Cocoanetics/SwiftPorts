import Foundation
import Testing
import ShellKit
@testable import SwiftGit

@Suite("Filter operation context lifetime")
struct GitFilterOperationContextTests {
    @Test("filter failures are immediate unless checkout explicitly opts in")
    func deferralDisabledByDefault() throws {
        let context = GitFilterOperationContext(
            shell: Shell(), credentials: nil, environment: .none, gate: ConfigIncludeGate(enforcing: false))
        var finished = false
        #expect(throws: GitFilterOperationContext.Failure.noOperation) {
            try context.run {
                try context.deferFailure(GitFilterOperationContext.Failure.noOperation)
                finished = true
            }
        }
        #expect(!finished)
    }

    @Test("deferred failure is raised after the body and the lease is revoked")
    func deferredFailure() async throws {
        let context = GitFilterOperationContext(
            shell: Shell(), credentials: nil, environment: .none, gate: ConfigIncludeGate(enforcing: false),
            deferFilterFailures: true)
        var finished = false
        #expect(throws: GitFilterOperationContext.Failure.unsupportedOperation) {
            try context.run {
                try context.deferFailure(GitFilterOperationContext.Failure.unsupportedOperation)
                try context.deferFailure(GitFilterOperationContext.Failure.noOperation)
                finished = true
            }
        }
        #expect(finished)
        #expect(throws: GitFilterOperationContext.Failure.noOperation) {
            _ = try GitFilterOperationContext.capture()
        }
        #expect(throws: GitFilterOperationContext.Failure.expired) {
            try context.deferFailure(GitFilterOperationContext.Failure.noOperation)
        }
    }

    @Test("a body failure takes precedence over deferred failure")
    func immediateFailure() throws {
        let context = GitFilterOperationContext(
            shell: Shell(), credentials: nil, environment: .none, gate: ConfigIncludeGate(enforcing: false),
            deferFilterFailures: true)
        #expect(throws: GitFilterOperationContext.Failure.noOperation) {
            try context.run {
                try context.deferFailure(GitFilterOperationContext.Failure.unsupportedOperation)
                throw GitFilterOperationContext.Failure.noOperation
            }
        }
    }

    @Test("capture is scoped to the operation and revoked on thrown return")
    func revokedOnFailure() async throws {
        let shell = Shell()
        let client = GitClient()
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
