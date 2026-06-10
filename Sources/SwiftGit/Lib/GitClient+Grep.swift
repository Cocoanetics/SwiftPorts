import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` grep operation
// (`GitKit/Repository+Grep.swift`).
// NB: no `GitClient.GrepMatch` alias — inside this module the name `GitKit`
// resolves to the namespace enum (which shadows the module), so a member
// typealias can't reference the module's type. Call sites use the bare
// `GrepMatch`, re-exported from GitKit.
extension GitClient {

    /// Search tracked (and optionally untracked) files for `pattern` — `git grep`.
    public func grep(
        pattern: String,
        options: NSRegularExpression.Options = [],
        pathFilters: [String] = [],
        includeUntracked: Bool = false
    ) async throws -> [GrepMatch] {
        try await withRepository {
            try $0.grep(
                pattern: pattern,
                options: options,
                pathFilters: pathFilters,
                includeUntracked: includeUntracked)
        }
    }

    /// Test seam: the glob matcher moved to `Repository.glob`.
    static func glob(pattern: String, name: String) -> Bool {
        Repository.glob(pattern: pattern, name: name)
    }
}
