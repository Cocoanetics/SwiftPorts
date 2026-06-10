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
}
