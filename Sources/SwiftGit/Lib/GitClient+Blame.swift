import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` blame operation
// (`GitKit/Repository+Blame.swift`).
extension GitClient {

    /// Walk `path`'s last-changed-commit hunks — `git blame <path>`.
    public func blame(path: String) async throws -> [BlameHunk] {
        try await withRepository { try $0.blame(path: path) }
    }
}
