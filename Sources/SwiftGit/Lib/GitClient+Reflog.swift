import Foundation
import SwiftGitCore

// Sandbox-aware delegation onto the pure `Repository` reflog operation
// (`SwiftGitCore/Repository+Reflog.swift`).
extension GitClient {

    /// Read the reflog for `refName` (default `HEAD`), newest first — `git reflog`.
    public func reflog(refName: String = "HEAD") async throws -> [ReflogEntry] {
        try await withRepository { try $0.reflog(refName: refName) }
    }
}
