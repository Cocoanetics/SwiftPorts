import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` rev-parse /
// ls-files operations (`GitKit/Repository+RevParse.swift`).
extension GitClient {

    /// Resolve `spec` to a full 40-char SHA — `git rev-parse <spec>`.
    public func resolveOID(_ spec: String) async throws -> String {
        try await withRepository { try $0.resolveOID(spec) }
    }

    /// Path to the repo's `.git` directory — `git rev-parse --git-dir`.
    public func gitDir() async throws -> String? {
        try await withRepository { try $0.gitDir() }
    }

    /// Working-tree root — `git rev-parse --show-toplevel`. Nil for bare repos.
    public func toplevel() async throws -> String? {
        try await withRepository { try $0.toplevel() }
    }

    /// Tracked file paths — `git ls-files` with no flags.
    public func indexedPaths() async throws -> [String] {
        try await withRepository { try $0.indexedPaths() }
    }

    /// Full index entries (mode, OID, stage, path) — `git ls-files -s`.
    public func indexedEntries() async throws -> [IndexedEntry] {
        try await withRepository { try $0.indexedEntries() }
    }

    /// True when `workingDirectory` is inside a non-bare repo.
    public func isInsideWorkTree() async throws -> Bool {
        // We rely on `withRepository` succeeding plus a non-nil
        // workdir to distinguish bare from non-bare.
        do {
            return try await withRepository { try $0.isInsideWorkTree() }
        } catch {
            return false
        }
    }
}
