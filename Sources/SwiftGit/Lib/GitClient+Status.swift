import Foundation
import ForgeKit
import libgit2

/// One entry in a `git status` report. We preserve both the index-side
/// state (HEAD ↔ index) and the workdir-side state (index ↔ working
/// tree) because real git's short format prints them as the two
/// columns `XY <path>`.
public struct StatusEntry: Sendable, Equatable {
    /// Repo-relative path. For renames this is the new path; the old
    /// path is in `oldPath`.
    public let path: String
    public let oldPath: String?

    public let indexState: ChangeKind
    public let workdirState: ChangeKind
    public let isUntracked: Bool
    public let isIgnored: Bool
    public let isConflicted: Bool

    public enum ChangeKind: Sendable, Equatable {
        case unchanged
        case newFile
        case modified
        case deleted
        case renamed
        case typeChange

        /// Real-git's single-letter column code for short / porcelain output.
        public var letter: Character {
            switch self {
            case .unchanged: return " "
            case .newFile: return "A"
            case .modified: return "M"
            case .deleted: return "D"
            case .renamed: return "R"
            case .typeChange: return "T"
            }
        }

        /// Real-git's verbose label (`new file:`, `modified:`, …).
        public var verboseLabel: String {
            switch self {
            case .unchanged: return ""
            case .newFile: return "new file"
            case .modified: return "modified"
            case .deleted: return "deleted"
            case .renamed: return "renamed"
            case .typeChange: return "typechange"
            }
        }
    }
}

/// Result of `Libgit2GitClient.status()`. The CLI bins these into the
/// real-git sections (Changes to be committed / Changes not staged /
/// Untracked / Unmerged) when formatting verbose output.
public struct StatusReport: Sendable {
    /// `main`, `feature/x`, …, or nil for detached HEAD.
    public let branchName: String?
    /// True when the repo has no commits yet (HEAD points at an
    /// unborn ref). Real git's verbose output adds "No commits yet".
    public let isUnborn: Bool
    /// Upstream tracking ref (e.g. `origin/main`), nil when the
    /// branch has no configured upstream.
    public let upstreamRef: String?
    /// Ahead / behind counts vs `upstreamRef`, nil when there's no
    /// upstream to compare against. Used for the `## main...origin/main
    /// [ahead 2, behind 1]` line in `--branch` output.
    public let ahead: Int?
    public let behind: Int?
    public let entries: [StatusEntry]

    public var stagedEntries:  [StatusEntry] { entries.filter { $0.indexState != .unchanged && !$0.isConflicted } }
    public var unstagedEntries:[StatusEntry] { entries.filter { $0.workdirState != .unchanged && !$0.isUntracked && !$0.isConflicted } }
    public var untrackedEntries:[StatusEntry] { entries.filter { $0.isUntracked } }
    public var conflictedEntries:[StatusEntry] { entries.filter { $0.isConflicted } }
    public var isClean: Bool { entries.isEmpty }
}

extension GitClient {

    /// Produce a `git status` snapshot for the working tree. Includes
    /// untracked files; ignored files are skipped (real git's default).
    public func status() async throws -> StatusReport {
        try await withRepository { repo in
            // Build options: include untracked + recurse into untracked dirs,
            // but skip ignored entries.
            var opts = git_status_options()
            try check(git_status_options_init(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION)))
            opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
            opts.flags =
                UInt32(GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue)
                | UInt32(GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue)
                | UInt32(GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue)
                | UInt32(GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR.rawValue)

            var list: OpaquePointer?
            try check(git_status_list_new(&list, repo, &opts))
            defer { git_status_list_free(list) }

            var entries: [StatusEntry] = []
            let count = Int(git_status_list_entrycount(list))
            for i in 0..<count {
                try Task.checkCancellation()
                guard let raw = git_status_byindex(list, i)?.pointee
                else { continue }
                if let e = makeEntry(raw) {
                    entries.append(e)
                }
            }

            // Branch + unborn-ness — match `git status`'s header logic.
            var head: OpaquePointer?
            let headRC = git_repository_head(&head, repo)
            var branchName: String? = nil
            var isUnborn = false
            if headRC == 0 {
                defer { git_reference_free(head) }
                if let cstr = git_reference_shorthand(head) {
                    let s = String(cString: cstr)
                    if s != "HEAD" { branchName = s }
                }
            } else if headRC == GIT_EUNBORNBRANCH.rawValue {
                isUnborn = true
                // Pull the planned branch name out of `HEAD` directly.
                var symbolic: OpaquePointer?
                if git_reference_lookup(&symbolic, repo, "HEAD") == 0 {
                    defer { git_reference_free(symbolic) }
                    if let cstr = git_reference_symbolic_target(symbolic) {
                        let target = String(cString: cstr)
                        let prefix = "refs/heads/"
                        if target.hasPrefix(prefix) {
                            branchName = String(target.dropFirst(prefix.count))
                        }
                    }
                }
            } else {
                try check(headRC)
            }

            // Upstream tracking + ahead/behind counts. Best-effort —
            // missing upstream just leaves the fields nil.
            var upstreamRef: String? = nil
            var ahead: Int? = nil
            var behind: Int? = nil
            if let branch = branchName, !isUnborn {
                upstreamRef = (try? upstreamShorthand(repo: repo, branch: branch))
                if upstreamRef != nil {
                    let counts = try? graphCounts(
                        repo: repo, branch: branch)
                    ahead = counts?.ahead
                    behind = counts?.behind
                }
            }

            return StatusReport(
                branchName: branchName, isUnborn: isUnborn,
                upstreamRef: upstreamRef, ahead: ahead, behind: behind,
                entries: entries)
        }
    }

    private func upstreamShorthand(repo: OpaquePointer?, branch: String) throws -> String? {
        var buf = git_buf()
        let rc = "refs/heads/\(branch)".withCString { full -> Int32 in
            git_branch_upstream_name(&buf, repo, full)
        }
        if rc != 0 { return nil }
        defer { git_buf_dispose(&buf) }
        guard let ptr = buf.ptr else { return nil }
        let full = String(cString: ptr)
        let prefix = "refs/remotes/"
        return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
    }

    private func graphCounts(repo: OpaquePointer?, branch: String) throws -> (ahead: Int, behind: Int)? {
        var localRef: OpaquePointer?
        let lrc = git_branch_lookup(&localRef, repo, branch, GIT_BRANCH_LOCAL)
        if lrc != 0 { return nil }
        defer { git_reference_free(localRef) }
        guard let localOID = git_reference_target(localRef) else { return nil }

        var upstreamRef: OpaquePointer?
        let urc = git_branch_upstream(&upstreamRef, localRef)
        if urc != 0 { return nil }
        defer { git_reference_free(upstreamRef) }
        guard let upstreamOID = git_reference_target(upstreamRef) else { return nil }

        var ahead: Int = 0
        var behind: Int = 0
        let rc = git_graph_ahead_behind(&ahead, &behind, repo, localOID, upstreamOID)
        if rc != 0 { return nil }
        return (ahead, behind)
    }

    /// Translate one `git_status_entry` into our `StatusEntry`.
    private func makeEntry(_ raw: git_status_entry) -> StatusEntry? {
        // Rename info lives in the diff_delta payloads. Prefer the
        // workdir delta's path if present (renames + later edits).
        let primaryDelta = raw.index_to_workdir ?? raw.head_to_index
        guard let dPtr = primaryDelta else { return nil }
        let delta = dPtr.pointee
        let newPath = String(cString: delta.new_file.path
            ?? delta.old_file.path)
        let oldPath: String? = {
            guard delta.status == GIT_DELTA_RENAMED else { return nil }
            return delta.old_file.path.map { String(cString: $0) }
        }()

        // Funnel libgit2's status bitmask + each `GIT_STATUS_*` constant
        // through `UInt32(...)` so the bitwise math typechecks under
        // both Apple/Linux's UInt32-rawValue import and clang-cl/MSVC's
        // Int32-rawValue import.
        let s = UInt32(raw.status.rawValue)
        let conflicted = (s & UInt32(GIT_STATUS_CONFLICTED.rawValue)) != 0
        let ignored = (s & UInt32(GIT_STATUS_IGNORED.rawValue)) != 0
        let untracked = (s & UInt32(GIT_STATUS_WT_NEW.rawValue)) != 0
            && (s & UInt32(0x7F)) == 0   // no index-side changes

        // Map the libgit2 status bitmask to our two column states.
        var index: StatusEntry.ChangeKind = .unchanged
        if      (s & UInt32(GIT_STATUS_INDEX_NEW.rawValue)) != 0       { index = .newFile }
        else if (s & UInt32(GIT_STATUS_INDEX_MODIFIED.rawValue)) != 0  { index = .modified }
        else if (s & UInt32(GIT_STATUS_INDEX_DELETED.rawValue)) != 0   { index = .deleted }
        else if (s & UInt32(GIT_STATUS_INDEX_RENAMED.rawValue)) != 0   { index = .renamed }
        else if (s & UInt32(GIT_STATUS_INDEX_TYPECHANGE.rawValue)) != 0{ index = .typeChange }

        var workdir: StatusEntry.ChangeKind = .unchanged
        if      (s & UInt32(GIT_STATUS_WT_NEW.rawValue)) != 0          { workdir = .newFile }
        if      (s & UInt32(GIT_STATUS_WT_MODIFIED.rawValue)) != 0     { workdir = .modified }
        else if (s & UInt32(GIT_STATUS_WT_DELETED.rawValue)) != 0      { workdir = .deleted }
        else if (s & UInt32(GIT_STATUS_WT_RENAMED.rawValue)) != 0      { workdir = .renamed }
        else if (s & UInt32(GIT_STATUS_WT_TYPECHANGE.rawValue)) != 0   { workdir = .typeChange }

        return StatusEntry(
            path: newPath, oldPath: oldPath,
            indexState: index, workdirState: workdir,
            isUntracked: untracked, isIgnored: ignored,
            isConflicted: conflicted)
    }
}

// MARK: Formatting

extension StatusReport {

    /// `[ahead N, behind M]` parts as real git formats them. Empty
    /// array when both counts are zero / nil.
    private func aheadBehindParts() -> [String] {
        var parts: [String] = []
        if let a = ahead, a > 0 { parts.append("ahead \(a)") }
        if let b = behind, b > 0 { parts.append("behind \(b)") }
        return parts
    }

    /// Real-git's `--short` / `--porcelain` format: `XY <path>` per
    /// entry. With `branchHeader: true`, prepend a `## <branch>` line
    /// (with `...<upstream> [ahead N, behind M]` when an upstream
    /// is configured).
    public func shortFormat(branchHeader: Bool = false) -> String {
        var out = ""
        if branchHeader {
            if isUnborn {
                out += "## No commits yet on \(branchName ?? "HEAD")\n"
            } else if let branch = branchName {
                if let upstream = upstreamRef {
                    var line = "## \(branch)...\(upstream)"
                    let parts = aheadBehindParts()
                    if !parts.isEmpty {
                        line += " [\(parts.joined(separator: ", "))]"
                    }
                    out += line + "\n"
                } else {
                    out += "## \(branch)\n"
                }
            } else {
                out += "## HEAD (no branch)\n"
            }
        }
        for e in entries {
            let x: Character
            let y: Character
            if e.isUntracked {
                x = "?"; y = "?"
            } else if e.isConflicted {
                x = "U"; y = "U"
            } else {
                x = e.indexState.letter
                y = e.workdirState.letter
            }
            out += "\(x)\(y) \(e.path)\n"
        }
        return out
    }

    /// Real-git's verbose `git status` format, including branch line,
    /// per-section headers + hint blocks, and the closing `nothing to
    /// commit` line when applicable.
    public func verboseFormat(palette: ColorPalette = .disabled) -> String {
        var out = "On branch \(palette.branch(branchName ?? "HEAD"))\n"
        if isUnborn {
            // Real git: blank line on either side of `No commits yet`.
            out += "\nNo commits yet\n\n"
        } else if let upstream = upstreamRef {
            // Real git's "Your branch is …" line.
            switch (ahead ?? 0, behind ?? 0) {
            case (0, 0):
                out += "Your branch is up to date with '\(upstream)'.\n\n"
            case (let a, 0) where a > 0:
                out += "Your branch is ahead of '\(upstream)' by \(a) commit\(a == 1 ? "" : "s").\n"
                out += "  (use \"git push\" to publish your local commits)\n\n"
            case (0, let b) where b > 0:
                out += "Your branch is behind '\(upstream)' by \(b) commit\(b == 1 ? "" : "s"), and can be fast-forwarded.\n"
                out += "  (use \"git pull\" to update your local branch)\n\n"
            case (let a, let b) where a > 0 && b > 0:
                out += "Your branch and '\(upstream)' have diverged,\nand have \(a) and \(b) different commits each, respectively.\n"
                out += "  (use \"git pull\" if you want to integrate the remote branch with yours)\n\n"
            default:
                break
            }
        }

        let staged = stagedEntries
        let unstaged = unstagedEntries
        let untracked = untrackedEntries
        let conflicts = conflictedEntries

        // Real git separates each non-empty section with one blank
        // line before its header, then ends with one trailing blank
        // line. We just emit `\n` before each section's body.

        if !staged.isEmpty {
            out += "Changes to be committed:\n"
            out += "  (use \"git restore --staged <file>...\" to unstage)\n"
            for e in staged {
                let label = e.indexState.verboseLabel
                let line: String
                if e.indexState == .renamed, let oldPath = e.oldPath {
                    line = "\(label):   \(oldPath) -> \(e.path)"
                } else {
                    line = "\(label):   \(e.path)"
                }
                out += "\t\(palette.staged(line))\n"
            }
            out += "\n"
        }

        if !unstaged.isEmpty {
            out += "Changes not staged for commit:\n"
            out += "  (use \"git add <file>...\" to update what will be committed)\n"
            out += "  (use \"git restore <file>...\" to discard changes in working directory)\n"
            for e in unstaged {
                let label = e.workdirState.verboseLabel
                out += "\t\(palette.unstaged("\(label):   \(e.path)"))\n"
            }
            out += "\n"
        }

        if !conflicts.isEmpty {
            out += "Unmerged paths:\n"
            out += "  (use \"git add <file>...\" to mark resolution)\n"
            for e in conflicts {
                out += "\t\(palette.unstaged("both modified:   \(e.path)"))\n"
            }
            out += "\n"
        }

        if !untracked.isEmpty {
            out += "Untracked files:\n"
            out += "  (use \"git add <file>...\" to include in what will be committed)\n"
            for e in untracked {
                out += "\t\(palette.unstaged(e.path))\n"
            }
            out += "\n"
        }

        if isClean {
            if isUnborn {
                out += "\nnothing to commit (create/copy files and use \"git add\" to track)\n"
            } else {
                out += "nothing to commit, working tree clean\n"
            }
        } else if staged.isEmpty && unstaged.isEmpty && conflicts.isEmpty {
            // Untracked-only scenario.
            out += "nothing added to commit but untracked files present (use \"git add\" to track)\n"
        }
        return out
    }
}
