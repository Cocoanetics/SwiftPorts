import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` diff operations
// (`GitKit/Repository+Diff.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// Produce diff output as a single string — mirrors `git diff`'s
    /// stdout for the matching invocation.
    public func diff(
        _ target: DiffTarget,
        format: DiffFormat = .patch,
        paths: [String] = [],
        contextLines: UInt32? = nil
    ) async throws -> String {
        try await withRepository {
            try $0.diff(target, format: format, paths: paths, contextLines: contextLines)
        }
    }

    /// True iff `spec` resolves to an object via `git_revparse_single`.
    public func canResolveRef(_ spec: String) async throws -> Bool {
        try await withRepository { try $0.canResolveRef(spec) }
    }

    /// Compute the merge-base of two commit-ishes.
    public func mergeBase(_ a: String, _ b: String) async throws -> String {
        try await withRepository { try $0.mergeBase(a, b) }
    }
}
