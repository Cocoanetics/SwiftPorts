import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` inspection
// operations (`GitKit/Repository+Inspection.swift`). Each call
// authorizes the working directory and isolates libgit2's global
// config view via `withRepository`, then hands off.
extension GitClient {

    /// Whether `path` is currently matched by a `.gitignore` rule.
    public func isIgnored(_ path: String) async throws -> Bool {
        try await withRepository { try $0.isIgnored(path) }
    }

    /// Local branch names in the repo.
    public func localBranches() async throws -> [String] {
        try await withRepository { try $0.localBranches() }
    }

    /// List configured remote names, sorted alphabetically.
    public func remoteList() async throws -> [String] {
        try await withRepository { try $0.remoteList() }
    }

    /// Delete a remote and the associated config entries.
    public func remoteDelete(name: String) async throws {
        try await withRepository { try $0.remoteDelete(name: name) }
    }

    /// Rename `oldName` → `newName`; returns unfixable refspec problems.
    @discardableResult
    public func remoteRename(from oldName: String, to newName: String) async throws -> [String] {
        try await withRepository { try $0.remoteRename(from: oldName, to: newName) }
    }

    /// Update an existing remote's URL.
    public func remoteSetURL(name: String, url: URL) async throws {
        try await withRepository { try $0.remoteSetURL(name: name, url: url) }
    }

    /// True when a remote with `name` is already configured.
    public func remoteExists(named name: String) async throws -> Bool {
        try await withRepository { try $0.remoteExists(named: name) }
    }

    /// Delete a local branch (`git branch -d <name>`, `-D` with `force`).
    public func branchDelete(name: String, force: Bool = false) async throws {
        try await withRepository { try $0.branchDelete(name: name, force: force) }
    }

    /// Rename `oldName` (or the current branch when nil) to `newName`.
    public func branchRename(
        from oldName: String? = nil, to newName: String, force: Bool = false
    ) async throws {
        try await withRepository {
            try $0.branchRename(from: oldName, to: newName, force: force)
        }
    }
}
