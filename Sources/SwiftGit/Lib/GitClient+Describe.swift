import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` describe operation
// (`GitKit/Repository+Describe.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// Mirrors `git describe` — most recent reachable tag plus a suffix
    /// when the commit is past that tag.
    public func describe(
        committish: String = "HEAD",
        tags: Bool = false,
        abbrev: Int = 7,
        dirty: Bool = false
    ) async throws -> String {
        try await withRepository {
            try $0.describe(committish: committish, tags: tags, abbrev: abbrev, dirty: dirty)
        }
    }
}
