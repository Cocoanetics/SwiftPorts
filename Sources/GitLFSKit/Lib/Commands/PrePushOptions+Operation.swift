import Foundation
import SwiftGit

extension PrePushOptions {
    /// Synchronous GitKit `beforeSending` adapter. Uses the enclosing operation's
    /// credentials and isolation; waits for uploads before returning. Pass the
    /// announced updates unchanged and the selected remote (including a temporary
    /// fork remote). Any nonzero command result is thrown, preventing ref updates.
    public func run(
        _ arguments: [String], updates: [LFSRefUpdate], at directory: URL, terminal: Bool = false
    ) throws -> LFSCommandResult {
        let operation = try GitFilterOperationContext.capture()
        try operation.checkCurrent()
        let result = try operation.runBlocking {
            try await operation.withLentClient(operation.client(at: directory)) { git in
                let client = await LFSClient(git: git, credentials: git.credentials)
                return try await run(arguments, updates: updates, client: client, git: git, terminal: terminal)
            }
        }
        guard result.status == 0 else { throw result }
        return result
    }
}
