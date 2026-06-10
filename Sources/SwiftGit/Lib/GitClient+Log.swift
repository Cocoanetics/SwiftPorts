import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` log operation
// (`GitKit/Repository+Log.swift`).
extension GitClient {

    /// Walk commit history per `query`, newest first — `git log`.
    public func log(_ query: LogQuery = LogQuery()) async throws -> [LogEntry] {
        try await withRepository { try $0.log(query) }
    }
}
