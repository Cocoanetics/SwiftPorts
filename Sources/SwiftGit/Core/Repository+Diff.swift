import Foundation
import CGitKit

/// Output mode for ``Repository/diff(_:format:paths:contextLines:)``.
public enum DiffFormat: Sendable {
    /// Standard unified diff (`git diff` / `-p` / `--patch`).
    case patch
    /// Per-file `+++/---` bar plus a summary line (`git diff --stat`).
    case stat
    /// Just the summary line, no per-file bars (`git diff --shortstat`).
    case shortStat
    /// `<insertions>\t<deletions>\t<path>` per file (`git diff --numstat`).
    case numStat
    /// `:<oldmode> <newmode> <oldsha> <newsha> <status>\t<path>` (`git diff --raw`).
    case raw
    /// One path per line (`git diff --name-only`).
    case nameOnly
    /// `<status>\t<path>` per file (`git diff --name-status`).
    case nameStatus
}

/// What to compare. Mirrors the common `git diff` invocations.
public enum DiffTarget: Sendable {
    /// Working tree vs index (`git diff`).
    case workdirVsIndex
    /// Index vs HEAD (`git diff --cached` / `--staged`).
    case indexVsHead
    /// Working tree vs a named commit-ish (`git diff <ref>`).
    case workdirVsCommit(String)
    /// Two commit-ishes (`git diff <a> <b>`).
    case commitVsCommit(String, String)
    /// Empty tree vs a commit-ish — every entry in the commit appears
    /// as an addition. Used to render `git log --stat` / `git show`
    /// for the root commit, which has no parent to diff against.
    case emptyVsCommit(String)
}

extension Repository {

    /// Produce diff output as a single string. Mirrors `git diff`'s
    /// stdout for the matching invocation. Returns the empty string
    /// when there are no changes (matches real-git silent-on-clean
    /// behaviour).
    public func diff(
        _ target: DiffTarget,
        format: DiffFormat = .patch,
        paths: [String] = [],
        contextLines: UInt32? = nil
    ) throws -> String {
        // Hold the strdup'd pathspec copies for the entire body so
        // libgit2 can read them while walking the diff.
        var copies: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
        defer { for c in copies { free(c) } }

        return try copies.withUnsafeMutableBufferPointer { pathBuf -> String in
            var opts = git_diff_options()
            try check(git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION)))
            if !paths.isEmpty {
                opts.pathspec = git_strarray(strings: pathBuf.baseAddress, count: pathBuf.count)
            }
            if let contextLines {
                opts.context_lines = contextLines
            }

            let diff = try buildDiff(target: target, repo: repo, opts: &opts)
            defer { git_diff_free(diff) }

            switch format {
            case .patch:
                return try formatBuf { git_diff_to_buf(&$0, diff, GIT_DIFF_FORMAT_PATCH) }
            case .raw:
                // libgit2's GIT_DIFF_FORMAT_RAW writes abbreviated
                // SHAs followed by `...` ellipsis — real git omits
                // the ellipsis. Roll our own formatter from the
                // diff deltas to match exactly.
                return formatRaw(diff: diff)
            case .nameOnly:
                return try formatBuf { git_diff_to_buf(&$0, diff, GIT_DIFF_FORMAT_NAME_ONLY) }
            case .nameStatus:
                return try formatBuf { git_diff_to_buf(&$0, diff, GIT_DIFF_FORMAT_NAME_STATUS) }
            case .stat:
                return try formatStats(diff: diff, statsFormat: GIT_DIFF_STATS_FULL)
            case .shortStat:
                return try formatStats(diff: diff, statsFormat: GIT_DIFF_STATS_SHORT)
            case .numStat:
                // libgit2's GIT_DIFF_STATS_NUMBER pads columns with
                // spaces; real git uses tab separators. Roll our own
                // by walking patches per delta.
                return try formatNumStat(diff: diff)
            }
        }
    }

    /// Produce real-git's `--raw` format by walking the diff deltas
    /// directly: `:<oldmode> <newmode> <oldsha7> <newsha7> <status>\t<path>`.
    /// Matches `git diff --raw` byte-for-byte.
    private func formatRaw(diff: OpaquePointer?) -> String {
        let count = Int(git_diff_num_deltas(diff))
        var out = ""
        for i in 0..<count {
            guard let delta = git_diff_get_delta(diff, i) else { continue }
            let d = delta.pointee
            let oldMode = String(format: "%06o", d.old_file.mode)
            let newMode = String(format: "%06o", d.new_file.mode)
            let oldSHA = abbrevOID(d.old_file.id)
            let newSHA = abbrevOID(d.new_file.id)
            let status = statusChar(d.status)
            let path = String(cString: d.new_file.path ?? d.old_file.path)
            out += ":\(oldMode) \(newMode) \(oldSHA) \(newSHA) \(status)\t\(path)\n"
        }
        return out
    }

    private func abbrevOID(_ oid: git_oid) -> String {
        var oid = oid
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 41)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: 41)
        _ = git_oid_tostr(buf, 41, &oid)
        return String(String(cString: buf).prefix(7))
    }

    private func statusChar(_ status: git_delta_t) -> String {
        switch status {
        case GIT_DELTA_ADDED: return "A"
        case GIT_DELTA_DELETED: return "D"
        case GIT_DELTA_MODIFIED: return "M"
        case GIT_DELTA_RENAMED: return "R"
        case GIT_DELTA_COPIED: return "C"
        case GIT_DELTA_TYPECHANGE: return "T"
        case GIT_DELTA_UNTRACKED: return "?"
        case GIT_DELTA_IGNORED: return "!"
        case GIT_DELTA_UNREADABLE: return "X"
        case GIT_DELTA_CONFLICTED: return "U"
        default: return "?"
        }
    }

    /// Tab-separated `<additions>\t<deletions>\t<path>` per file —
    /// matches `git diff --numstat` exactly.
    private func formatNumStat(diff: OpaquePointer?) throws -> String {
        let count = Int(git_diff_num_deltas(diff))
        var out = ""
        for i in 0..<count {
            try Task.checkCancellation()
            var patch: OpaquePointer?
            try check(git_patch_from_diff(&patch, diff, i))
            defer { git_patch_free(patch) }

            var ctx: Int = 0, adds: Int = 0, dels: Int = 0
            try check(git_patch_line_stats(&ctx, &adds, &dels, patch))

            guard let delta = git_diff_get_delta(diff, i) else { continue }
            let path = String(cString: delta.pointee.new_file.path
                ?? delta.pointee.old_file.path)
            out += "\(adds)\t\(dels)\t\(path)\n"
        }
        return out
    }

    private func formatStats(
        diff: OpaquePointer?,
        statsFormat: git_diff_stats_format_t
    ) throws -> String {
        var stats: OpaquePointer?
        try check(git_diff_get_stats(&stats, diff))
        defer { git_diff_stats_free(stats) }
        return try formatBuf { git_diff_stats_to_buf(&$0, stats, statsFormat, 80) }
    }

    private func buildDiff(
        target: DiffTarget,
        repo: OpaquePointer?,
        opts: inout git_diff_options
    ) throws -> OpaquePointer? {
        var diff: OpaquePointer?
        switch target {
        case .workdirVsIndex:
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            try check(git_diff_index_to_workdir(&diff, repo, index, &opts))

        case .indexVsHead:
            var head: OpaquePointer?
            let rc = git_repository_head(&head, repo)
            var headTree: OpaquePointer?
            if rc == 0 {
                defer { git_reference_free(head) }
                if let target = git_reference_target(head) {
                    var oid = target.pointee
                    var commit: OpaquePointer?
                    try check(git_commit_lookup(&commit, repo, &oid))
                    defer { git_commit_free(commit) }
                    if let treeID = git_commit_tree_id(commit) {
                        var treeOID = treeID.pointee
                        try check(git_tree_lookup(&headTree, repo, &treeOID))
                    }
                }
            } else if rc != GIT_EUNBORNBRANCH.rawValue && rc != GIT_ENOTFOUND.rawValue {
                try check(rc)
            }
            defer { if headTree != nil { git_tree_free(headTree) } }

            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            try check(git_diff_tree_to_index(&diff, repo, headTree, index, &opts))

        case .workdirVsCommit(let spec):
            let tree = try resolveTree(spec: spec, repo: repo)
            defer { git_tree_free(tree) }
            try check(git_diff_tree_to_workdir_with_index(&diff, repo, tree, &opts))

        case .commitVsCommit(let a, let b):
            let oldTree = try resolveTree(spec: a, repo: repo)
            defer { git_tree_free(oldTree) }
            let newTree = try resolveTree(spec: b, repo: repo)
            defer { git_tree_free(newTree) }
            try check(git_diff_tree_to_tree(&diff, repo, oldTree, newTree, &opts))

        case .emptyVsCommit(let spec):
            // libgit2 treats a NULL old-tree as the empty tree, so every
            // file in `newTree` shows up as an addition — exactly what
            // real git renders for `log --stat` / `show` on the root
            // commit.
            let newTree = try resolveTree(spec: spec, repo: repo)
            defer { git_tree_free(newTree) }
            try check(git_diff_tree_to_tree(&diff, repo, nil, newTree, &opts))
        }
        return diff
    }

    private func resolveTree(spec: String, repo: OpaquePointer?) throws -> OpaquePointer? {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, repo, spec))
        defer { git_object_free(object) }

        // Peel into a tree (supports commit-ish, tag, tree).
        var tree: OpaquePointer?
        try check(git_object_peel(&tree, object, GIT_OBJECT_TREE))
        return tree
    }

    /// True iff `spec` resolves to an object via `git_revparse_single`.
    /// Used for smart ref-vs-path disambiguation in `git diff <foo>`.
    public func canResolveRef(_ spec: String) throws -> Bool {
        var object: OpaquePointer?
        let rc = git_revparse_single(&object, repo, spec)
        if rc == 0 { git_object_free(object); return true }
        return false
    }

    /// Compute the merge-base of two commit-ishes — used to implement
    /// the `<a>...<b>` triple-dot diff notation.
    public func mergeBase(_ a: String, _ b: String) throws -> String {
        var aObj: OpaquePointer?
        try check(git_revparse_single(&aObj, repo, a))
        defer { git_object_free(aObj) }
        var bObj: OpaquePointer?
        try check(git_revparse_single(&bObj, repo, b))
        defer { git_object_free(bObj) }

        guard let aOID = git_object_id(aObj), let bOID = git_object_id(bObj) else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "could not resolve ids for \(a) / \(b)")
        }
        var out = git_oid()
        try check(git_merge_base(&out, repo, aOID, bOID))
        return formatOID(&out)
    }

    /// Run `body` against a fresh `git_buf`, return the contents as
    /// a Swift `String`, then dispose the buffer. libgit2 always
    /// NUL-terminates so `String(cString:)` is safe.
    private func formatBuf(_ body: (inout git_buf) -> Int32) throws -> String {
        var buf = git_buf()
        try check(body(&buf))
        defer { git_buf_dispose(&buf) }
        guard let ptr = buf.ptr else { return "" }
        return String(cString: ptr)
    }
}
