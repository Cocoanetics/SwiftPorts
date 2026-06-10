import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` status operation
// (`GitKit/Repository+Status.swift`). The call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// Produce a `git status` snapshot for the working tree. Includes
    /// untracked files; ignored files are skipped (real git's default).
    public func status() async throws -> StatusReport {
        try await withRepository { try $0.status() }
    }
}
