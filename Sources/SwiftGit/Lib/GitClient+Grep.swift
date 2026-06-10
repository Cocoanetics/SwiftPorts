import Foundation
import SwiftGitCore

// Sandbox-aware delegation onto the pure `Repository` grep operation
// (`SwiftGitCore/Repository+Grep.swift`).
extension GitClient {

    /// The match type now lives in SwiftGitCore — this alias keeps the
    /// `GitClient.GrepMatch` spelling working for existing call sites.
    public typealias GrepMatch = SwiftGitCore.GrepMatch

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
