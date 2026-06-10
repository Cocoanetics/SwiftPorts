import Foundation
import ForgeKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` stash operations
// (`GitKit/Repository+Stash.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// Snapshot the working directory + index into a new stash entry on
    /// `refs/stash`. Returns the SHA of the stash commit.
    @discardableResult
    public func stashSave(
        message: String?,
        author: GitSignature?,
        flags: StashSaveFlags = .default
    ) async throws -> String {
        try await withRepository {
            try $0.stashSave(message: message, author: author.core, flags: flags)
        }
    }

    /// Apply stash entry `index` (0 = most recent) to the working tree.
    /// `reinstateIndex == true` corresponds to `git stash apply --index`.
    public func stashApply(index: Int, reinstateIndex: Bool = false) async throws {
        try await withRepository {
            try $0.stashApply(index: index, reinstateIndex: reinstateIndex)
        }
    }

    /// Apply + drop. Equivalent to `git stash pop`.
    public func stashPop(index: Int, reinstateIndex: Bool = false) async throws {
        try await withRepository {
            try $0.stashPop(index: index, reinstateIndex: reinstateIndex)
        }
    }

    /// Remove a single stash entry without applying it.
    public func stashDrop(index: Int) async throws {
        try await withRepository { try $0.stashDrop(index: index) }
    }

    /// List all stash entries, most-recent first (index 0).
    public func stashList() async throws -> [Libgit2StashEntry] {
        try await withRepository { try $0.stashList() }
    }

    /// Drop every stash entry.
    public func stashClear() async throws {
        try await withRepository { try $0.stashClear() }
    }

    /// Diff stat between a stash entry and its parent.
    public func stashShow(index: Int) async throws -> (filesChanged: Int, insertions: Int, deletions: Int) {
        try await withRepository { try $0.stashShow(index: index) }
    }

    /// Compose `git stash branch <new>` from libgit2 primitives.
    public func stashBranch(name: String, index: Int = 0) async throws {
        try await withRepository { try $0.stashBranch(name: name, index: index) }
    }
}
