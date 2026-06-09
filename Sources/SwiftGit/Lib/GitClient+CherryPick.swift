import Foundation
import ForgeKit
import libgit2

/// Result of a `git cherry-pick`.
public enum CherryPickOutcome: Sendable {
    /// Clean apply: a new commit was created. `authorDate` is the
    /// **original** commit's author date (not "now"), since cherry-pick
    /// preserves authorship — that's the value real git shows in
    /// `Date: <…>`.
    case completed(sha: String, shortSHA: String, branchName: String?,
                   subject: String, authorDate: String,
                   statSummary: String, addedFiles: [String], deletedFiles: [String])
    /// libgit2 left the index conflicted; resolve + `--continue` (or
    /// `--skip` / `--abort`) to proceed. The original commit's metadata
    /// is persisted in `.git/CHERRY_PICK_HEAD` for the continue path.
    case conflict(commitSHA: String, commitSubject: String, paths: [String])
    /// `--abort` / `--skip` succeeded; nothing to commit.
    case cleared
}

extension GitClient {

    /// Cherry-pick a single commit on top of HEAD. Equivalent to
    /// `git cherry-pick <commit>`. On clean apply, creates a new
    /// commit; on conflict, leaves the index conflicted with
    /// `.git/CHERRY_PICK_HEAD` set so the caller can resume.
    @discardableResult
    public func cherryPick(
        _ ref: String,
        author: GitSignature? = nil
    ) async throws -> CherryPickOutcome {
        try await withRepository { repo in
            // Resolve the ref to a commit.
            var commitObj: OpaquePointer?
            try check(git_revparse_single(&commitObj, repo, ref))
            defer { git_object_free(commitObj) }

            var oid = git_object_id(commitObj)?.pointee ?? git_oid()
            var sourceCommit: OpaquePointer?
            try check(git_commit_lookup(&sourceCommit, repo, &oid))
            defer { git_commit_free(sourceCommit) }

            // Apply via libgit2 — this writes any conflicts into the
            // index + working tree (with markers) and persists state
            // in `.git/CHERRY_PICK_HEAD`.
            var opts = git_cherrypick_options()
            try check(git_cherrypick_options_init(
                &opts, UInt32(GIT_CHERRYPICK_OPTIONS_VERSION)))
            opts.checkout_opts.checkout_strategy =
                UInt32(GIT_CHECKOUT_SAFE.rawValue) | UInt32(GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue)
            try check(git_cherrypick(repo, sourceCommit, &opts))

            // Conflict?
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            if git_index_has_conflicts(index) != 0 {
                let info = try sourceInfo(commit: sourceCommit, oid: &oid)
                let paths = try cherryPickConflictPaths(index: index)
                return .conflict(
                    commitSHA: info.shortSHA,
                    commitSubject: info.subject,
                    paths: paths)
            }

            // Clean apply → write the commit. Uses source's author as
            // the commit author and our committer signature for
            // committer (matches real git behaviour).
            return try writeCherryPickCommit(
                repo: repo, sourceCommit: sourceCommit, sourceOID: &oid,
                authorOverride: author)
        }
    }

    /// Resume a paused cherry-pick after the user resolved conflicts
    /// and `git add`'d the files. Reads the original commit's metadata
    /// from `.git/CHERRY_PICK_HEAD`.
    @discardableResult
    public func cherryPickContinue(
        author: GitSignature? = nil
    ) async throws -> CherryPickOutcome {
        try await withRepository { repo in
            // CHERRY_PICK_HEAD points at the commit we were applying.
            var head: OpaquePointer?
            let rc = git_reference_lookup(&head, repo, "CHERRY_PICK_HEAD")
            if rc == GIT_ENOTFOUND.rawValue {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "no cherry-pick in progress")
            }
            try check(rc)
            defer { git_reference_free(head) }

            guard let target = git_reference_target(head) else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "CHERRY_PICK_HEAD has no oid")
            }
            var oid = target.pointee
            var sourceCommit: OpaquePointer?
            try check(git_commit_lookup(&sourceCommit, repo, &oid))
            defer { git_commit_free(sourceCommit) }

            // Verify the index is now clean (user resolved conflicts).
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            if git_index_has_conflicts(index) != 0 {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "cherry-pick still has conflicts")
            }

            return try writeCherryPickCommit(
                repo: repo, sourceCommit: sourceCommit, sourceOID: &oid,
                authorOverride: author)
        }
    }

    /// `git cherry-pick --abort`: undo the in-progress cherry-pick
    /// (`git_repository_state_cleanup` + `git_reset --hard HEAD`).
    public func cherryPickAbort() async throws {
        try await withRepository { repo in
            // Sanity: there has to actually be a cherry-pick in flight.
            var head: OpaquePointer?
            let rc = git_reference_lookup(&head, repo, "CHERRY_PICK_HEAD")
            if rc == GIT_ENOTFOUND.rawValue {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "no cherry-pick in progress")
            }
            try check(rc)
            git_reference_free(head)

            // Reset --hard to current HEAD to wipe the conflict state.
            var headRef: OpaquePointer?
            try check(git_repository_head(&headRef, repo))
            defer { git_reference_free(headRef) }
            guard let target = git_reference_target(headRef) else { return }
            var oid = target.pointee
            var commit: OpaquePointer?
            try check(git_commit_lookup(&commit, repo, &oid))
            defer { git_commit_free(commit) }

            try check(git_reset(repo, commit, GIT_RESET_HARD, nil))
            try check(git_repository_state_cleanup(repo))
        }
    }

    /// `git cherry-pick --skip`: drop the conflicting commit and
    /// continue (which here means: clean up state without committing).
    /// Real git `--skip` only matters in multi-commit cherry-pick
    /// sequences; with single-commit it's effectively the same as
    /// abort + a clean working tree.
    public func cherryPickSkip() async throws {
        try await cherryPickAbort()
    }

    // MARK: helpers

    private func writeCherryPickCommit(
        repo: OpaquePointer?,
        sourceCommit: OpaquePointer?,
        sourceOID: inout git_oid,
        authorOverride: GitSignature?
    ) throws -> CherryPickOutcome {
        // Prior tree (HEAD) for stat output.
        var headRef: OpaquePointer?
        try check(git_repository_head(&headRef, repo))
        defer { git_reference_free(headRef) }
        guard let parentTarget = git_reference_target(headRef) else {
            throw Libgit2Error(code: -1, klass: 0, message: "HEAD has no oid")
        }
        var parentOID = parentTarget.pointee
        var parentCommit: OpaquePointer?
        try check(git_commit_lookup(&parentCommit, repo, &parentOID))
        defer { git_commit_free(parentCommit) }

        var parentTree: OpaquePointer?
        if let id = git_commit_tree_id(parentCommit) {
            var tid = id.pointee
            try check(git_tree_lookup(&parentTree, repo, &tid))
        }
        defer { if parentTree != nil { git_tree_free(parentTree) } }

        // Resolved tree from the conflict-free index.
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index))
        var newTree: OpaquePointer?
        try check(git_tree_lookup(&newTree, repo, &treeOID))
        defer { git_tree_free(newTree) }

        // Author = source commit's author (real git's default), unless
        // overridden. Committer = our env-resolved identity.
        let sourceAuthor = git_commit_author(sourceCommit)
        var authorSig: UnsafeMutablePointer<git_signature>?
        if let authorOverride {
            try check(authorOverride.name.withCString { n in
                authorOverride.email.withCString { e in
                    git_signature_now(&authorSig, n, e)
                }
            })
        } else if sourceAuthor != nil {
            try check(git_signature_dup(&authorSig, sourceAuthor))
        } else {
            try check(git_signature_default(&authorSig, repo))
        }
        defer { git_signature_free(authorSig) }

        let committerSig = try SignatureResolver.resolve(
            role: .committer, repo: repo)
        defer { git_signature_free(committerSig) }

        // Use source's commit message verbatim.
        let messagePtr = git_commit_message(sourceCommit)
        let message = messagePtr.map { String(cString: $0) } ?? ""

        var commitOID = git_oid()
        var parents: [OpaquePointer?] = [parentCommit]
        _ = try parents.withUnsafeMutableBufferPointer { pbuf in
            try message.withCString { msg in
                try check(git_commit_create(
                    &commitOID, repo, "HEAD", authorSig, committerSig, nil,
                    msg, newTree, pbuf.count, pbuf.baseAddress))
            }
        }

        // Cleanup CHERRY_PICK_HEAD + state files.
        try check(git_repository_state_cleanup(repo))

        // Format the [branch sha] message + short stat block.
        let stats = try collectCherryPickStats(
            repo: repo, oldTree: parentTree, newTree: newTree)
        let sha = formatOID(&commitOID)
        let subject = message.split(separator: "\n").first.map(String.init) ?? ""

        var branchName: String? = nil
        var head2: OpaquePointer?
        if git_repository_head(&head2, repo) == 0 {
            defer { git_reference_free(head2) }
            if let cstr = git_reference_shorthand(head2) {
                let s = String(cString: cstr)
                if s != "HEAD" { branchName = s }
            }
        }

        // The original commit's author timestamp is what real git
        // surfaces as `Date:` after cherry-pick (because the new
        // commit inherits authorship — only the committer is "now").
        let authorDate: String = {
            guard let sig = sourceAuthor?.pointee else { return "" }
            return formatGitDate(time: sig.when.time, offset: sig.when.offset)
        }()

        return .completed(
            sha: sha, shortSHA: String(sha.prefix(7)),
            branchName: branchName, subject: subject, authorDate: authorDate,
            statSummary: stats.summary,
            addedFiles: stats.added,
            deletedFiles: stats.deleted)
    }

    /// Real-git `Date:`-line format: `EEE MMM d HH:mm:ss yyyy ±HHMM`.
    /// libgit2 hands us seconds-since-epoch + tz-minutes; we reconstruct
    /// the calendar string in the right locale + offset.
    private func formatGitDate(time: git_time_t, offset: Int32) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(time))
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: Int(offset) * 60)
        let body = f.string(from: date)
        let sign = offset >= 0 ? "+" : "-"
        let absMin = abs(Int(offset))
        let zone = String(format: "%@%02d%02d", sign, absMin / 60, absMin % 60)
        return "\(body) \(zone)"
    }

    /// Same shape as merge's `collectStats` — couldn't share directly
    /// because it's `private`. Pulls full `--stat` block + add/delete
    /// mode lines for the cherry-pick summary.
    private func collectCherryPickStats(
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

        // Cherry-pick's summary is real-git's `--shortstat` form (just
        // the totals line, no per-file bars). Merge/commit use FULL.
        var buf = git_buf()
        try check(git_diff_stats_to_buf(&buf, stats, GIT_DIFF_STATS_SHORT, 80))
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

    private func cherryPickConflictPaths(index: OpaquePointer?) throws -> [String] {
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
            let entry = ours ?? theirs ?? ancestor
            if let p = entry?.pointee.path {
                paths.append(String(cString: p))
            }
        }
        return paths
    }

    private func sourceInfo(
        commit: OpaquePointer?,
        oid: inout git_oid
    ) throws -> (shortSHA: String, subject: String) {
        let sha = formatOID(&oid)
        let messagePtr = git_commit_message(commit)
        let message = messagePtr.map { String(cString: $0) } ?? ""
        let subject = message.split(separator: "\n").first.map(String.init) ?? ""
        return (String(sha.prefix(7)), subject)
    }
}
