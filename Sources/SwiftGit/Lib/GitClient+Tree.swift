import Foundation
import libgit2

/// One entry produced by `lsTree`. Mirrors a single line of `git
/// ls-tree`'s default output: `<mode> <type> <sha>\t<name>`.
public struct TreeEntry: Sendable {
    /// File type: blob (file), tree (subdirectory), commit (submodule).
    public enum Kind: String, Sendable {
        case blob, tree, commit, tag
    }
    /// Octal mode string (e.g. `"100644"`).
    public let mode: String
    public let kind: Kind
    /// SHA-1 of the referenced object.
    public let sha: String
    /// Path relative to the requested tree's root. With `recursive`,
    /// includes intermediate directory components.
    public let path: String
}

extension GitClient {

    /// List the entries inside a tree (or a commit's tree). Defaults to
    /// the immediate children of `HEAD^{tree}`. With `recursive: true`,
    /// blob entries from subtrees are flattened into the result, mirror-
    /// ing `git ls-tree -r`. (Subtrees themselves are still emitted —
    /// real git omits them under `-r` unless `-t` is also passed.)
    public func lsTree(
        treeish: String = "HEAD",
        recursive: Bool = false
    ) async throws -> [TreeEntry] {
        try await withRepository { repo in
            var obj: OpaquePointer?
            try check(treeish.withCString { name in
                git_revparse_single(&obj, repo, name)
            })
            defer { git_object_free(obj) }

            var tree: OpaquePointer?
            try check(git_object_peel(&tree, obj, GIT_OBJECT_TREE))
            defer { git_object_free(tree) }

            if recursive {
                return try walkRecursive(repo: repo, tree: tree)
            }
            return readImmediate(tree: tree)
        }
    }

    private func readImmediate(tree: OpaquePointer?) -> [TreeEntry] {
        let count = git_tree_entrycount(tree)
        var entries: [TreeEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            guard let entry = git_tree_entry_byindex(tree, i) else { continue }
            entries.append(treeEntry(from: entry, prefix: ""))
        }
        return entries
    }

    private func walkRecursive(
        repo: OpaquePointer?, tree: OpaquePointer?
    ) throws -> [TreeEntry] {
        var collected: [TreeEntry] = []
        // Iterative DFS — libgit2's git_tree_walk uses a callback +
        // payload, but Swift closures can't be passed as @convention(c)
        // without a trampoline. Spelling out the walk inline here
        // keeps the result type-safe and avoids the boxing dance.
        var stack: [(OpaquePointer?, String)] = [(tree, "")]
        while let (current, prefix) = stack.popLast() {
            try Task.checkCancellation()
            let count = git_tree_entrycount(current)
            for i in 0..<count {
                guard let entry = git_tree_entry_byindex(current, i) else { continue }
                let info = treeEntry(from: entry, prefix: prefix)
                collected.append(info)
                if info.kind == .tree {
                    var sub: OpaquePointer?
                    if git_tree_lookup(&sub, repo, git_tree_entry_id(entry)) == 0 {
                        stack.append((sub, info.path + "/"))
                    }
                }
            }
        }
        return collected
    }

    private func treeEntry(
        from entry: OpaquePointer, prefix: String
    ) -> TreeEntry {
        let name = String(cString: git_tree_entry_name(entry))
        let mode = String(format: "%06o", git_tree_entry_filemode(entry).rawValue)
        let kind: TreeEntry.Kind
        switch git_tree_entry_type(entry) {
        case GIT_OBJECT_BLOB: kind = .blob
        case GIT_OBJECT_TREE: kind = .tree
        case GIT_OBJECT_COMMIT: kind = .commit
        case GIT_OBJECT_TAG: kind = .tag
        default: kind = .blob
        }
        var oid = git_tree_entry_id(entry)?.pointee ?? git_oid()
        let sha = formatOID(&oid)
        return TreeEntry(mode: mode, kind: kind, sha: sha, path: prefix + name)
    }
}
