import Foundation
import ForgeKit
import libgit2

/// Single entry returned by ``GitClient/stashList()``.
public struct Libgit2StashEntry: Sendable {
    /// Position in the stash list. `0` is the most recent.
    public let index: Int
    /// `WIP on <branch>: <sha> <subject>` style message that git stores.
    public let message: String
    /// SHA of the commit holding the stashed state.
    public let sha: String
}

/// Options for ``GitClient/stashSave(message:author:flags:)``. Mirrors
/// the bits real `git stash push` exposes.
public struct StashSaveFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let `default`         = StashSaveFlags([])
    public static let keepIndex         = StashSaveFlags(rawValue: UInt32(GIT_STASH_KEEP_INDEX.rawValue))
    public static let includeUntracked  = StashSaveFlags(rawValue: UInt32(GIT_STASH_INCLUDE_UNTRACKED.rawValue))
    public static let includeIgnored    = StashSaveFlags(rawValue: UInt32(GIT_STASH_INCLUDE_IGNORED.rawValue))
}

extension GitClient {

    /// Snapshot the working directory + index into a new stash entry on
    /// `refs/stash`. Returns the SHA of the stash commit. Throws if the
    /// repo has nothing to stash (libgit2 returns `GIT_ENOTFOUND` in
    /// that case — we let it propagate as `Libgit2Error`).
    @discardableResult
    public func stashSave(
        message: String?,
        author: GitSignature?,
        flags: StashSaveFlags = .default
    ) async throws -> String {
        try await withRepository { repo in
            var signature: UnsafeMutablePointer<git_signature>?
            if let author {
                try check(author.name.withCString { n in
                    author.email.withCString { e in
                        git_signature_now(&signature, n, e)
                    }
                })
            } else {
                try check(git_signature_default(&signature, repo))
            }
            defer { git_signature_free(signature) }

            var oid = git_oid()
            let rc: Int32
            if let message {
                rc = message.withCString { msg in
                    git_stash_save(&oid, repo, signature, msg, flags.rawValue)
                }
            } else {
                rc = git_stash_save(&oid, repo, signature, nil, flags.rawValue)
            }
            try check(rc)
            return formatOID(&oid)
        }
    }

    /// Apply stash entry `index` (0 = most recent) to the working tree.
    /// `reinstateIndex == true` corresponds to `git stash apply --index`.
    public func stashApply(index: Int, reinstateIndex: Bool = false) async throws {
        try await withRepository { repo in
            var opts = git_stash_apply_options()
            try check(git_stash_apply_options_init(
                &opts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION)))
            if reinstateIndex {
                opts.flags = UInt32(GIT_STASH_APPLY_REINSTATE_INDEX.rawValue)
            }
            try check(git_stash_apply(repo, index, &opts))
        }
    }

    /// Apply + drop. Equivalent to `git stash pop`.
    public func stashPop(index: Int, reinstateIndex: Bool = false) async throws {
        try await withRepository { repo in
            var opts = git_stash_apply_options()
            try check(git_stash_apply_options_init(
                &opts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION)))
            if reinstateIndex {
                opts.flags = UInt32(GIT_STASH_APPLY_REINSTATE_INDEX.rawValue)
            }
            try check(git_stash_pop(repo, index, &opts))
        }
    }

    /// Remove a single stash entry without applying it.
    public func stashDrop(index: Int) async throws {
        _ = try await withRepository { repo in
            try check(git_stash_drop(repo, index))
        }
    }

    /// List all stash entries, most-recent first (index 0).
    public func stashList() async throws -> [Libgit2StashEntry] {
        try await withRepository { repo in
            // libgit2's foreach takes a payload — wrap our collector
            // in a class so the C trampoline can mutate it via
            // `Unmanaged.passUnretained`.
            final class Collector { var items: [Libgit2StashEntry] = [] }
            let collector = Collector()
            let raw = Unmanaged.passUnretained(collector).toOpaque()

            let cb: git_stash_cb = { idx, msgPtr, oidPtr, payload in
                guard let payload, let oidPtr else { return 0 }
                let c = Unmanaged<Collector>.fromOpaque(payload).takeUnretainedValue()
                let msg = msgPtr.map { String(cString: $0) } ?? ""
                let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 41)
                defer { buf.deallocate() }
                buf.initialize(repeating: 0, count: 41)
                _ = git_oid_tostr(buf, 41, oidPtr)
                let sha = String(cString: buf)
                c.items.append(Libgit2StashEntry(index: Int(idx), message: msg, sha: sha))
                return 0
            }
            try check(git_stash_foreach(repo, cb, raw))
            return collector.items
        }
    }

    /// Drop every stash entry. Walks newest-first because each drop
    /// shifts the indices of older entries down by one.
    public func stashClear() async throws {
        let entries = try await stashList()
        for entry in entries.sorted(by: { $0.index < $1.index }).reversed() {
            try await stashDrop(index: entry.index)
        }
    }

    /// Diff stat between a stash entry and its parent (i.e. what the
    /// stash modified relative to HEAD when it was created). Returns
    /// the same triple `commitDetailed` uses.
    public func stashShow(index: Int) async throws -> (filesChanged: Int, insertions: Int, deletions: Int) {
        try await withRepository { repo in
            // Look up `stash@{N}` by walking the stash list — using
            // git_revparse_single("stash@{N}") would be brittle if the
            // reflog is empty. The foreach gives us the OID directly.
            final class Finder {
                let target: Int
                var oid: git_oid?
                init(target: Int) { self.target = target }
            }
            let finder = Finder(target: index)
            let raw = Unmanaged.passUnretained(finder).toOpaque()
            let cb: git_stash_cb = { idx, _, oidPtr, payload in
                guard let payload, let oidPtr else { return 0 }
                let f = Unmanaged<Finder>.fromOpaque(payload).takeUnretainedValue()
                if Int(idx) == f.target { f.oid = oidPtr.pointee; return 1 }
                return 0
            }
            _ = git_stash_foreach(repo, cb, raw)
            guard var stashOID = finder.oid else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "stash@{\(index)} does not exist")
            }

            var stashCommit: OpaquePointer?
            try check(git_commit_lookup(&stashCommit, repo, &stashOID))
            defer { git_commit_free(stashCommit) }

            // Parent[0] of a stash commit is the original HEAD; the
            // tree-to-tree diff against it reflects what the stash
            // changed in the working tree.
            var parentOID = git_oid()
            if let target = git_commit_parent_id(stashCommit, 0) {
                parentOID = target.pointee
            }
            var parentCommit: OpaquePointer?
            try check(git_commit_lookup(&parentCommit, repo, &parentOID))
            defer { git_commit_free(parentCommit) }

            var stashTreeID = git_oid(), parentTreeID = git_oid()
            if let id = git_commit_tree_id(stashCommit) { stashTreeID = id.pointee }
            if let id = git_commit_tree_id(parentCommit) { parentTreeID = id.pointee }

            var stashTree: OpaquePointer?
            try check(git_tree_lookup(&stashTree, repo, &stashTreeID))
            defer { git_tree_free(stashTree) }
            var parentTree: OpaquePointer?
            try check(git_tree_lookup(&parentTree, repo, &parentTreeID))
            defer { git_tree_free(parentTree) }

            var diff: OpaquePointer?
            try check(git_diff_tree_to_tree(&diff, repo, parentTree, stashTree, nil))
            defer { git_diff_free(diff) }

            var stats: OpaquePointer?
            try check(git_diff_get_stats(&stats, diff))
            defer { git_diff_stats_free(stats) }

            return (
                filesChanged: Int(git_diff_stats_files_changed(stats)),
                insertions: Int(git_diff_stats_insertions(stats)),
                deletions: Int(git_diff_stats_deletions(stats)))
        }
    }

    /// Compose `git stash branch <new>` from libgit2 primitives:
    /// 1. Look up `stash@{N}`, walk to its first parent (= the commit
    ///    that was HEAD when the stash was made).
    /// 2. Create a new local branch at that parent.
    /// 3. Check the branch out and apply the stash, then drop it.
    public func stashBranch(name: String, index: Int = 0) async throws {
        try await withRepository { repo in
            // Resolve stash@{N} → parent OID.
            final class Finder {
                let target: Int; var oid: git_oid?
                init(target: Int) { self.target = target }
            }
            let finder = Finder(target: index)
            let raw = Unmanaged.passUnretained(finder).toOpaque()
            let cb: git_stash_cb = { idx, _, oidPtr, payload in
                guard let payload, let oidPtr else { return 0 }
                let f = Unmanaged<Finder>.fromOpaque(payload).takeUnretainedValue()
                if Int(idx) == f.target { f.oid = oidPtr.pointee; return 1 }
                return 0
            }
            _ = git_stash_foreach(repo, cb, raw)
            guard var stashOID = finder.oid else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "stash@{\(index)} does not exist")
            }

            var stashCommit: OpaquePointer?
            try check(git_commit_lookup(&stashCommit, repo, &stashOID))
            defer { git_commit_free(stashCommit) }

            guard let parentTarget = git_commit_parent_id(stashCommit, 0) else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "stash@{\(index)} has no parent")
            }
            var parentOID = parentTarget.pointee

            var parentCommit: OpaquePointer?
            try check(git_commit_lookup(&parentCommit, repo, &parentOID))
            defer { git_commit_free(parentCommit) }

            // Create the branch ref pointing at the parent commit.
            var newBranch: OpaquePointer?
            try check(git_branch_create(&newBranch, repo, name, parentCommit, 0))
            defer { git_reference_free(newBranch) }

            // Check the new branch out. Same pattern as `Checkout`.
            var object: OpaquePointer?
            try check(git_revparse_single(&object, repo, name))
            defer { git_object_free(object) }
            var opts = git_checkout_options()
            try check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            opts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)
            try check(git_checkout_tree(repo, object, &opts))
            if let refName = git_reference_name(newBranch) {
                try check(git_repository_set_head(repo, refName))
            }

            // Apply + drop.
            var applyOpts = git_stash_apply_options()
            try check(git_stash_apply_options_init(
                &applyOpts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION)))
            try check(git_stash_apply(repo, index, &applyOpts))
            try check(git_stash_drop(repo, index))
        }
    }
}
