import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` reset operations
// (`GitKit/Repository+Reset.swift`).
extension GitClient {

    /// Reset HEAD (and optionally the index + working tree) to `target` —
    /// `git reset [--soft|--mixed|--hard] [<commit>]`.
    @discardableResult
    public func reset(
        to target: String = "HEAD",
        mode: ResetMode = .mixed
    ) async throws -> ResetOutcome {
        try await withRepository { try $0.reset(to: target, mode: mode) }
    }

    /// Per-pathspec reset (`git reset HEAD <paths>`): copy the listed
    /// entries from `target`'s tree into the index.
    @discardableResult
    public func reset(paths: [String], from target: String = "HEAD") async throws -> ResetOutcome {
        try await withRepository { try $0.reset(paths: paths, from: target) }
    }
}
