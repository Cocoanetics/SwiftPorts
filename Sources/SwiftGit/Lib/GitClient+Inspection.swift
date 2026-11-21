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

    /// Remote-tracking branches (`git branch -r`), sorted by name.
    /// `origin/HEAD` is included. Pass a remote to keep only that remote.
    public func remoteBranches(remote: String? = nil) async throws -> [RemoteBranch] {
        try await withFilterMetadataRepository { try $0.remoteBranches(remote: remote) }
    }

    /// References under `refs/` whose full name matches `pattern`.
    ///
    /// `nil` lists every one of them: branches, remote-tracking branches,
    /// tags, notes and stash. `HEAD` is a pseudoref and is not included.
    /// Symbolic refs are resolved; `targetSHA` is the object the ref names
    /// (an annotated tag's tag object, as `git for-each-ref` reports
    /// `%(objectname)`). A dangling symbolic ref is omitted.
    public func references(matching pattern: String? = nil) async throws -> [ReferenceEntry] {
        try await withFilterMetadataRepository { try $0.references(matching: pattern) }
    }

    /// List configured remote names, sorted alphabetically.
    public func remoteList() async throws -> [String] {
        try await withFilterMetadataRepository { try $0.remoteList() }
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
