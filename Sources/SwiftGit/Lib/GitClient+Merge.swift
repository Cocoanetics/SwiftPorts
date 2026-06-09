import Foundation
import ForgeKit
import libgit2

/// What `git merge`'s fast-forward decision was. Mirrors libgit2's
/// `git_merge_analysis_t` filtered through the user's `--ff` choice.
public enum MergeOutcome: Sendable {
    /// HEAD already contains the target commit — no work done.
    case alreadyUpToDate
    /// HEAD was advanced to the target commit; no merge commit
    /// created. Carries the previous and new HEAD shas for the
    /// `Updating <a>..<b>` line and a per-file diff stat summary.
    case fastForward(oldSHA: String, newSHA: String, statSummary: String, addedFiles: [String], deletedFiles: [String])
    /// A real 3-way merge succeeded, a merge commit was created, and
    /// the working tree now matches it.
    case mergeCommit(sha: String, statSummary: String, addedFiles: [String], deletedFiles: [String])
    /// A 3-way merge produced conflicts. The index is left in the
    /// conflicted state and the caller must resolve + commit. Carries
    /// the conflicted paths for the `CONFLICT (content): …` lines.
    case conflicts(paths: [String])
}

/// Fast-forward preference selectable on `GitClient.merge`.
public enum FastForwardMode: Sendable {
    /// Fast-forward when possible, otherwise create a merge commit.
    /// Default behaviour of `git merge`.
    case auto
    /// Always create a merge commit, even when FF is possible.
    case never
    /// Only fast-forward; abort with a `Libgit2Error` if not possible.
    case onlyFastForward
}

extension GitClient {

    /// Run a real-git-style merge of `theirRef` into HEAD.
    ///
    /// The author/message are only used when this turns into a 3-way
    /// merge (FF doesn't create a commit). When `message` is nil we
    /// fall back to `Merge branch '<short-shorthand>'`, matching real
    /// git's default subject line.
    public func merge(
        ref theirRef: String,
        fastForward: FastForwardMode = .auto,
        message: String? = nil,
        author: GitSignature? = nil
    ) async throws -> MergeOutcome {
        try await withRepository { repo in
            // Resolve the named ref into an annotated commit.
            var theirAC: OpaquePointer?
            let acRC = git_annotated_commit_from_revspec(&theirAC, repo, theirRef)
            if acRC == GIT_ENOTFOUND.rawValue {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "merge: \(theirRef) - not something we can merge")
            }
            try check(acRC)
            defer { git_annotated_commit_free(theirAC) }

            // Run analysis to decide FF / normal / up-to-date.
            var analysis = git_merge_analysis_t(0)
            var preference = git_merge_preference_t(0)
            var heads: [OpaquePointer?] = [theirAC]
            _ = try heads.withUnsafeMutableBufferPointer { headBuf in
                try check(git_merge_analysis(
                    &analysis, &preference, repo, headBuf.baseAddress, 1))
            }

            if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
                return .alreadyUpToDate
            }

            // Resolve the target commit OID for both FF and merge-commit paths.
            guard let theirOIDPtr = git_annotated_commit_id(theirAC) else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "merge: failed to resolve target oid")
            }
            var theirOID = theirOIDPtr.pointee

            // Snapshot HEAD's SHA + tree before any writes.
            let oldSHA = try currentHeadSHA(repo: repo)
            var oldTree: OpaquePointer?
            if let oldSHA, var oldOID = parseOID(oldSHA) {
                var oldCommit: OpaquePointer?
                try check(git_commit_lookup(&oldCommit, repo, &oldOID))
                defer { git_commit_free(oldCommit) }
                if let id = git_commit_tree_id(oldCommit) {
                    var tid = id.pointee
                    try check(git_tree_lookup(&oldTree, repo, &tid))
                }
            }
            defer { if oldTree != nil { git_tree_free(oldTree) } }

            let canFF = analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0

            switch fastForward {
            case .onlyFastForward:
                if !canFF {
                    throw Libgit2Error(code: -1, klass: 0,
                        message: "Not possible to fast-forward, aborting.")
                }
                return try performFastForward(
                    repo: repo, theirOID: &theirOID, theirRef: theirRef,
                    oldSHA: oldSHA, oldTree: oldTree)

            case .auto:
                if canFF {
                    return try performFastForward(
                        repo: repo, theirOID: &theirOID, theirRef: theirRef,
                        oldSHA: oldSHA, oldTree: oldTree)
                }
                fallthrough

            case .never:
                return try performMergeCommit(
                    repo: repo, theirAC: theirAC, theirRef: theirRef,
                    theirOID: &theirOID, oldTree: oldTree,
                    message: message, author: author)
            }
        }
    }

    // MARK: Fast-forward

    private func performFastForward(
        repo: OpaquePointer?,
        theirOID: inout git_oid,
        theirRef: String,
        oldSHA: String?,
        oldTree: OpaquePointer?
    ) throws -> MergeOutcome {
        // Fetch the target commit, point HEAD at it, check out the tree.
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &theirOID))
        defer { git_commit_free(commit) }
        guard let treeID = git_commit_tree_id(commit) else {
            throw Libgit2Error(code: -1, klass: 0, message: "FF: missing tree id")
        }
        var newTreeOID = treeID.pointee
        var newTree: OpaquePointer?
        try check(git_tree_lookup(&newTree, repo, &newTreeOID))
        defer { git_tree_free(newTree) }

        var coOpts = git_checkout_options()
        try check(git_checkout_options_init(&coOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        coOpts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)
        try check(git_checkout_tree(repo, newTree, &coOpts))

        // Update the current branch ref to point at the new commit. If
        // HEAD is detached, just set HEAD detached to the new oid.
        var head: OpaquePointer?
        if git_repository_head(&head, repo) == 0 {
            defer { git_reference_free(head) }
            var newRef: OpaquePointer?
            try check(git_reference_set_target(&newRef, head, &theirOID,
                "merge: Fast-forward".cString(using: .utf8)))
            git_reference_free(newRef)
        } else {
            try check(git_repository_set_head_detached(repo, &theirOID))
        }

        // Diff stats vs the prior tree for the `<n> file changed, …` line
        // plus per-file create/delete mode lines.
        let stats = try collectStats(repo: repo, oldTree: oldTree, newTree: newTree)

        let newSHA = formatOID(&theirOID)
        return .fastForward(
            oldSHA: oldSHA ?? "0000000000000000000000000000000000000000",
            newSHA: newSHA,
            statSummary: stats.summary,
            addedFiles: stats.added,
            deletedFiles: stats.deleted)
    }

    // MARK: 3-way merge commit

    private func performMergeCommit(
        repo: OpaquePointer?,
        theirAC: OpaquePointer?,
        theirRef: String,
        theirOID: inout git_oid,
        oldTree: OpaquePointer?,
        message: String?,
        author: GitSignature?
    ) throws -> MergeOutcome {
        var mergeOpts = git_merge_options()
        try check(git_merge_options_init(&mergeOpts, UInt32(GIT_MERGE_OPTIONS_VERSION)))
        var coOpts = git_checkout_options()
        try check(git_checkout_options_init(&coOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
        coOpts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)
            | UInt32(GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue)

        var heads: [OpaquePointer?] = [theirAC]
        _ = try heads.withUnsafeMutableBufferPointer { buf in
            try check(git_merge(repo, buf.baseAddress, 1, &mergeOpts, &coOpts))
        }

        // Did libgit2 leave the index conflicted?
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        if git_index_has_conflicts(index) != 0 {
            return .conflicts(paths: try conflictPaths(index: index))
        }

        // No conflicts → write the merge commit. Two parents: HEAD,
        // their commit. Tree comes from the resolved index.
        var parentHead: OpaquePointer?
        try check(git_repository_head(&parentHead, repo))
        defer { git_reference_free(parentHead) }
        guard let pid = git_reference_target(parentHead) else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "merge commit: HEAD has no oid")
        }
        var parentOID = pid.pointee
        var parentCommit: OpaquePointer?
        try check(git_commit_lookup(&parentCommit, repo, &parentOID))
        defer { git_commit_free(parentCommit) }

        var theirCommit: OpaquePointer?
        try check(git_commit_lookup(&theirCommit, repo, &theirOID))
        defer { git_commit_free(theirCommit) }

        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index))
        var newTree: OpaquePointer?
        try check(git_tree_lookup(&newTree, repo, &treeOID))
        defer { git_tree_free(newTree) }

        var sig: UnsafeMutablePointer<git_signature>?
        if let author {
            try check(author.name.withCString { n in
                author.email.withCString { e in
                    git_signature_now(&sig, n, e)
                }
            })
        } else {
            try check(git_signature_default(&sig, repo))
        }
        defer { git_signature_free(sig) }

        let resolvedMessage = message ?? defaultMergeMessage(refName: theirRef)
        var commitOID = git_oid()
        var parents: [OpaquePointer?] = [parentCommit, theirCommit]
        _ = try parents.withUnsafeMutableBufferPointer { pbuf in
            try resolvedMessage.withCString { msg in
                try check(git_commit_create(
                    &commitOID, repo, "HEAD", sig, sig, nil,
                    msg, newTree, pbuf.count, pbuf.baseAddress))
            }
        }

        // Commit done — tell libgit2 we're not in a merging state anymore.
        try check(git_repository_state_cleanup(repo))

        let stats = try collectStats(repo: repo, oldTree: oldTree, newTree: newTree)
        return .mergeCommit(
            sha: formatOID(&commitOID),
            statSummary: stats.summary,
            addedFiles: stats.added,
            deletedFiles: stats.deleted)
    }

    // MARK: Helpers

    /// Real-git-style stats block — per-file bars + summary line —
    /// pulled straight from libgit2's `--stat` formatter so the merge
    /// output matches `git merge` byte-for-byte. Also returns the
    /// `create mode` / `delete mode` lines for files added or removed.
    private func collectStats(
        repo: OpaquePointer?,
        oldTree: OpaquePointer?,
        newTree: OpaquePointer?
    ) throws -> (summary: String, added: [String], deleted: [String]) {
        var diff: OpaquePointer?
        try check(git_diff_tree_to_tree(&diff, repo, oldTree, newTree, nil))
        defer { git_diff_free(diff) }

        var stats: OpaquePointer?
        try check(git_diff_get_stats(&stats, diff))
        defer { git_diff_stats_free(stats) }

        // Full stat block: per-file bars + summary, identical to
        // `git --stat` (terminating newline included).
        var buf = git_buf()
        try check(git_diff_stats_to_buf(&buf, stats, GIT_DIFF_STATS_FULL, 80))
        defer { git_buf_dispose(&buf) }
        let summary = (buf.ptr.map { String(cString: $0) } ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))

        var added: [String] = []
        var deleted: [String] = []
        let n = Int(git_diff_num_deltas(diff))
        for i in 0..<n {
            guard let d = git_diff_get_delta(diff, i) else { continue }
            let dd = d.pointee
            switch dd.status {
            case GIT_DELTA_ADDED:
                let mode = String(format: "%06o", dd.new_file.mode)
                let path = String(cString: dd.new_file.path)
                added.append(" create mode \(mode) \(path)")
            case GIT_DELTA_DELETED:
                let mode = String(format: "%06o", dd.old_file.mode)
                let path = String(cString: dd.old_file.path)
                deleted.append(" delete mode \(mode) \(path)")
            default:
                break
            }
        }
        return (summary, added, deleted)
    }

    private func conflictPaths(index: OpaquePointer?) throws -> [String] {
        var iter: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iter, index))
        defer { git_index_conflict_iterator_free(iter) }

        var paths: [String] = []
        while true {
            var ancestor: UnsafePointer<git_index_entry>?
            var ours: UnsafePointer<git_index_entry>?
            var theirs: UnsafePointer<git_index_entry>?
            let rc = git_index_conflict_next(&ancestor, &ours, &theirs, iter)
            if rc == GIT_ITEROVER.rawValue { break }
            try check(rc)
            // Prefer ours' path; fall back to theirs / ancestor.
            let entry = ours ?? theirs ?? ancestor
            if let p = entry?.pointee.path {
                paths.append(String(cString: p))
            }
        }
        return paths
    }

    private func currentHeadSHA(repo: OpaquePointer?) throws -> String? {
        var head: OpaquePointer?
        let rc = git_repository_head(&head, repo)
        if rc == GIT_EUNBORNBRANCH.rawValue || rc == GIT_ENOTFOUND.rawValue {
            return nil
        }
        try check(rc)
        defer { git_reference_free(head) }
        guard let target = git_reference_target(head) else { return nil }
        var oid = target.pointee
        return formatOID(&oid)
    }

    private func parseOID(_ sha: String) -> git_oid? {
        var oid = git_oid()
        let rc = sha.withCString { git_oid_fromstr(&oid, $0) }
        return rc == 0 ? oid : nil
    }

    /// Fetch then merge — `git pull` semantics.
    ///
    /// `branch` defaults to the current branch's name. After the fetch,
    /// the remote-tracking ref `<remote>/<branch>` is the merge target.
    public func pull(
        remote: String = "origin",
        branch: String? = nil,
        fastForward: FastForwardMode = .auto,
        message: String? = nil,
        author: GitSignature? = nil
    ) async throws -> MergeOutcome {
        let local: String
        if let branch {
            local = branch
        } else {
            local = (try await currentBranch()) ?? "HEAD"
        }
        try await fetch(remote: remote, refspec: local)
        return try await merge(
            ref: "\(remote)/\(local)",
            fastForward: fastForward,
            message: message,
            author: author)
    }

    /// Fetch then rebase — `git pull --rebase` semantics. Replays the
    /// local branch's commits since their merge-base with
    /// `<remote>/<branch>` on top of the freshly-fetched ref.
    public func pullRebase(
        remote: String = "origin",
        branch: String? = nil,
        author: GitSignature? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RebaseOutcome {
        let local: String
        if let branch {
            local = branch
        } else {
            local = (try await currentBranch()) ?? "HEAD"
        }
        try await fetch(remote: remote, refspec: local)
        return try await rebase(
            upstream: "\(remote)/\(local)",
            author: author,
            progress: progress)
    }

    private func defaultMergeMessage(refName: String) -> String {
        // Real git formats this as: "Merge branch 'feature'\n" for
        // local refs, "Merge branch 'feature' of <remote>" for remote
        // tracking refs, etc. For our subset, match the local case —
        // strip any "refs/heads/" prefix.
        let stripped = refName.hasPrefix("refs/heads/")
            ? String(refName.dropFirst("refs/heads/".count))
            : refName
        return "Merge branch '\(stripped)'"
    }
}
