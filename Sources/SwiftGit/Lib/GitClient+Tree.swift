import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` tree listing
// (`GitKit/Repository+Tree.swift`). The call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// List the entries inside a tree (or a commit's tree), mirroring
    /// `git ls-tree` (and `git ls-tree -r` with `recursive: true`).
    public func lsTree(
        treeish: String = "HEAD",
        recursive: Bool = false
    ) async throws -> [TreeEntry] {
        try await withRepository {
            try $0.lsTree(treeish: treeish, recursive: recursive)
        }
    }

    /// Recursively load blobs from `treeish` in `git ls-tree -r` order.
    public func treeBlobs(
        of treeish: String,
        prefix: String = ""
    ) async throws -> [TreeBlob] {
        try await withRepository {
            try $0.treeBlobs(of: treeish, prefix: prefix)
        }
    }

    /// Commit timestamp for `treeish`, or nil for raw trees.
    public func commitTime(of treeish: String) async throws -> Date? {
        try await withRepository {
            try $0.commitTime(of: treeish)
        }
    }
}
