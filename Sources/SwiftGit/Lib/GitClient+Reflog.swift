import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` reflog operation
// (`GitKit/Repository+Reflog.swift`).
extension GitClient {

    /// Read the reflog for `refName` (default `HEAD`), newest first — `git reflog`.
    public func reflog(refName: String = "HEAD") async throws -> [ReflogEntry] {
        try await withRepository { try $0.reflog(refName: refName) }
    }
}
