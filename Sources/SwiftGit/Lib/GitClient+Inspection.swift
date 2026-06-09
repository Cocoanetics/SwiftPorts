import Foundation
import ShellKit
import libgit2

/// Rich result returned by ``GitClient/commitDetailed(message:author:allowEmpty:)``.
/// The CLI uses this to format `git commit`'s `[branch sha] message` line
/// plus the `<n> file(s) changed, <i> insertion(s)(+), <d> deletion(s)(-)`
/// summary and the per-file `create mode` / `delete mode` lines.
public struct Libgit2CommitDetails: Sendable {
    public let sha: String
    public let shortSHA: String
    public let branchName: String?
    public let isRoot: Bool
    public let filesChanged: Int
    public let insertions: Int
    public let deletions: Int
    public let addedFiles: [FileChange]
    public let deletedFiles: [FileChange]

    public struct FileChange: Sendable {
        public let path: String
        public let mode: UInt32
    }
}

extension GitClient {
    /// Whether `path` (relative to the repo workdir) is currently
    /// matched by a `.gitignore` rule. Throws on libgit2 failure;
    /// `false` if the path doesn't exist or isn't ignored.
    public func isIgnored(_ path: String) async throws -> Bool {
        try await withRepository { repo in
            var ignored: Int32 = 0
            try check(git_ignore_path_is_ignored(&ignored, repo, path))
            return ignored != 0
        }
    }

    /// Local branch names in the repo. Order matches libgit2's iterator
    /// (typically refdb order — alphabetical for refs/heads/*).
    public func localBranches() async throws -> [String] {
        try await withRepository { repo in
            var iter: OpaquePointer?
            try check(git_branch_iterator_new(&iter, repo, GIT_BRANCH_LOCAL))
            defer { git_branch_iterator_free(iter) }

            var names: [String] = []
            while true {
                try Task.checkCancellation()
                var ref: OpaquePointer?
                var branchType = GIT_BRANCH_LOCAL
                let rc = git_branch_next(&ref, &branchType, iter)
                if rc == GIT_ITEROVER.rawValue { break }
                try check(rc)
                defer { git_reference_free(ref) }
                if let cstr = git_branch_name_cstr(ref) {
                    names.append(String(cString: cstr))
                }
            }
            return names
        }
    }
}

/// Helper: libgit2's `git_branch_name` writes into a buffer, but the
/// shorthand is simpler. We use `git_reference_shorthand` since for
/// `refs/heads/X` it returns `X`.
private func git_branch_name_cstr(_ ref: OpaquePointer?) -> UnsafePointer<CChar>? {
    git_reference_shorthand(ref)
}

extension GitClient {
    /// List configured remote names. Sorted alphabetically to match
    /// `git remote`'s default order.
    public func remoteList() async throws -> [String] {
        try await withRepository { repo in
            var arr = git_strarray()
            try check(git_remote_list(&arr, repo))
            defer { git_strarray_dispose(&arr) }
            var names: [String] = []
            for i in 0..<arr.count {
                if let cstr = arr.strings?[i] {
                    names.append(String(cString: cstr))
                }
            }
            return names.sorted()
        }
    }

    /// Delete a remote and the associated `branch.<x>.remote` config
    /// entries (libgit2 does the cleanup).
    public func remoteDelete(name: String) async throws {
        _ = try await withRepository { repo in
            try check(name.withCString { n in
                git_remote_delete(repo, n)
            })
        }
    }

    /// Rename `oldName` → `newName`. Returns the list of unfixable
    /// branch refspec problems libgit2 surfaces (typically empty).
    @discardableResult
    public func remoteRename(from oldName: String, to newName: String) async throws -> [String] {
        try await withRepository { repo in
            var problems = git_strarray()
            try check(git_remote_rename(&problems, repo, oldName, newName))
            defer { git_strarray_dispose(&problems) }
            var names: [String] = []
            for i in 0..<problems.count {
                if let cstr = problems.strings?[i] {
                    names.append(String(cString: cstr))
                }
            }
            return names
        }
    }

    /// Update an existing remote's URL.
    public func remoteSetURL(name: String, url: URL) async throws {
        _ = try await withRepository { repo in
            try check(name.withCString { n in
                url.absoluteString.withCString { u in
                    git_remote_set_url(repo, n, u)
                }
            })
        }
    }

    /// True when a remote with `name` is already configured. Mirrors
    /// `git config remote.<name>.url` existence; used by `git remote add`
    /// to fail fast with the same error wording git uses.
    public func remoteExists(named name: String) async throws -> Bool {
        try await withRepository { repo in
            var remote: OpaquePointer?
            let rc = git_remote_lookup(&remote, repo, name)
            if rc == 0 {
                git_remote_free(remote)
                return true
            }
            if rc == GIT_ENOTFOUND.rawValue { return false }
            try check(rc)
            return false
        }
    }

    /// Delete a local branch. Equivalent to `git branch -d <name>`
    /// (or `-D` with `force`).
    public func branchDelete(name: String, force: Bool = false) async throws {
        try await withRepository { repo in
            var ref: OpaquePointer?
            let lookupRC = git_branch_lookup(&ref, repo, name, GIT_BRANCH_LOCAL)
            if lookupRC == GIT_ENOTFOUND.rawValue {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "branch '\(name)' not found.")
            }
            try check(lookupRC)
            defer { git_reference_free(ref) }

            // Real git's `-d` (without `-D`) errors when the branch
            // hasn't been merged into HEAD; libgit2 doesn't enforce
            // that, so we run the check ourselves via descendant_of.
            if !force, try unmergedAgainstHead(repo: repo, ref: ref) {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "the branch '\(name)' is not fully merged.")
            }
            try check(git_branch_delete(ref))
        }
    }

    /// Rename `oldName` (or the current branch when nil) to `newName`.
    /// `force == true` overwrites an existing branch with the new name.
    public func branchRename(
        from oldName: String? = nil, to newName: String, force: Bool = false
    ) async throws {
        // Resolve the current branch outside withRepository so we can
        // call our async accessor; the rename then runs in one txn.
        let resolvedOld: String
        if let oldName {
            resolvedOld = oldName
        } else {
            guard let current = try await currentBranch() else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "no current branch to rename")
            }
            resolvedOld = current
        }
        try await withRepository { repo in
            var ref: OpaquePointer?
            try check(git_branch_lookup(&ref, repo, resolvedOld, GIT_BRANCH_LOCAL))
            defer { git_reference_free(ref) }
            var newRef: OpaquePointer?
            try check(git_branch_move(&newRef, ref, newName, force ? 1 : 0))
            git_reference_free(newRef)
        }
    }

    /// Helper: true when `ref`'s commit is NOT reachable from HEAD.
    /// Used by `branchDelete` to mimic real git's `-d` safety check.
    private func unmergedAgainstHead(repo: OpaquePointer?, ref: OpaquePointer?) throws -> Bool {
        guard let target = git_reference_target(ref) else { return false }
        var head: OpaquePointer?
        let headRC = git_repository_head(&head, repo)
        if headRC != 0 { return false }
        defer { git_reference_free(head) }
        guard let headTarget = git_reference_target(head) else { return false }

        var refOID = target.pointee
        var headOID = headTarget.pointee
        // Same-commit case: branches pointing at HEAD are considered
        // merged (real git allows `-d` here without complaint).
        if withUnsafePointer(to: &refOID, { ref in
            withUnsafePointer(to: &headOID, { head in
                git_oid_cmp(ref, head) == 0
            })
        }) {
            return false
        }
        let rc = git_graph_descendant_of(repo, &headOID, &refOID)
        if rc < 0 { return false }
        return rc == 0  // 1 = HEAD descends from ref → merged; 0 = unmerged
    }
}
