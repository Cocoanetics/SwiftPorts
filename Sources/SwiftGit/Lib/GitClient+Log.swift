import Foundation
import ForgeKit
import libgit2

/// One commit returned by ``GitClient/log(query:)``.
public struct LogEntry: Sendable {
    public let sha: String
    public let shortSHA: String
    public let treeSHA: String
    public let parentSHAs: [String]

    public let authorName: String
    public let authorEmail: String
    public let authorTime: TimeInterval
    public let authorOffsetMinutes: Int

    public let committerName: String
    public let committerEmail: String
    public let committerTime: TimeInterval
    public let committerOffsetMinutes: Int

    public let message: String

    /// First line of the message (what `%s` resolves to).
    public var subject: String {
        message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    /// Everything after the subject + a blank separator line (what
    /// `%b` resolves to). Empty string if there's no body.
    public var body: String {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return "" }
        // Real git's `%b`: drop the subject + the blank line separator.
        var rest = Array(lines.dropFirst())
        if rest.first?.isEmpty == true { rest.removeFirst() }
        return rest.joined(separator: "\n")
    }

    public var isMerge: Bool { parentSHAs.count > 1 }
}

/// Query parameters for `git log`. Mirrors the common real-git flags.
public struct LogQuery: Sendable {
    /// Start points to walk from. When empty, falls back to HEAD.
    public var starts: [String]
    /// Commits whose ancestors should be excluded (the `^<ref>` /
    /// `<a>..<b>` form pushes `b` and hides `a`).
    public var excludes: [String]
    /// Limit the number of commits returned. `nil` = unbounded.
    public var maxCount: Int?
    /// Pathspec filter. Commits that don't touch any of these paths
    /// are skipped.
    public var paths: [String]

    public init(
        starts: [String] = [],
        excludes: [String] = [],
        maxCount: Int? = nil,
        paths: [String] = []
    ) {
        self.starts = starts
        self.excludes = excludes
        self.maxCount = maxCount
        self.paths = paths
    }
}

extension GitClient {

    /// Walk commit history per `query` and return the visited commits
    /// in topological/date order (libgit2's `revwalk` default — newest
    /// first, matching `git log` defaults).
    public func log(_ query: LogQuery = LogQuery()) async throws -> [LogEntry] {
        try await withRepository { repo in
            var walker: OpaquePointer?
            try check(git_revwalk_new(&walker, repo))
            defer { git_revwalk_free(walker) }

            try check(git_revwalk_sorting(walker,
                UInt32(GIT_SORT_TIME.rawValue) | UInt32(GIT_SORT_TOPOLOGICAL.rawValue)))

            // Push starts (or HEAD if none specified).
            if query.starts.isEmpty {
                // Probe HEAD first — `git_revwalk_push_head` collapses
                // the unborn / not-found cases into generic GIT_ERROR
                // (-1), which we can't disambiguate after the fact.
                var head: OpaquePointer?
                let headRC = git_repository_head(&head, repo)
                if headRC == GIT_ENOTFOUND.rawValue
                    || headRC == GIT_EUNBORNBRANCH.rawValue {
                    return []
                }
                try check(headRC)
                git_reference_free(head)
                try check(git_revwalk_push_head(walker))
            } else {
                for spec in query.starts {
                    var oid = git_oid()
                    var obj: OpaquePointer?
                    try check(git_revparse_single(&obj, repo, spec))
                    if let obj { oid = git_object_id(obj)?.pointee ?? oid }
                    git_object_free(obj)
                    try check(git_revwalk_push(walker, &oid))
                }
            }

            // Hide excluded commits + their ancestors.
            for spec in query.excludes {
                var obj: OpaquePointer?
                try check(git_revparse_single(&obj, repo, spec))
                var oid = git_object_id(obj)?.pointee ?? git_oid()
                git_object_free(obj)
                try check(git_revwalk_hide(walker, &oid))
            }

            // For path filtering we'll build a pathspec once and reuse.
            var pathCopies: [UnsafeMutablePointer<CChar>?] = query.paths.map { strdup($0) }
            defer { for p in pathCopies { free(p) } }

            var entries: [LogEntry] = []
            while query.maxCount.map({ entries.count < $0 }) ?? true {
                try Task.checkCancellation()
                var oid = git_oid()
                let rc = git_revwalk_next(&oid, walker)
                if rc == GIT_ITEROVER.rawValue { break }
                try check(rc)

                // Path filter: skip commits that don't touch any
                // listed path. We diff against the first parent (or the
                // empty tree for the root commit).
                if !query.paths.isEmpty {
                    let touches = try commitTouchesPaths(
                        repo: repo, oid: &oid, pathCopies: &pathCopies)
                    if !touches { continue }
                }

                if let entry = try makeLogEntry(repo: repo, oid: oid) {
                    entries.append(entry)
                }
            }
            return entries
        }
    }

    private func commitTouchesPaths(
        repo: OpaquePointer?,
        oid: inout git_oid,
        pathCopies: inout [UnsafeMutablePointer<CChar>?]
    ) throws -> Bool {
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &oid))
        defer { git_commit_free(commit) }
        guard let treeID = git_commit_tree_id(commit) else { return false }
        var newTreeOID = treeID.pointee
        var newTree: OpaquePointer?
        try check(git_tree_lookup(&newTree, repo, &newTreeOID))
        defer { git_tree_free(newTree) }

        // Parent tree (nil for root commit).
        var oldTree: OpaquePointer?
        if git_commit_parentcount(commit) > 0,
           let parentOIDPtr = git_commit_parent_id(commit, 0) {
            var parentOID = parentOIDPtr.pointee
            var parentCommit: OpaquePointer?
            try check(git_commit_lookup(&parentCommit, repo, &parentOID))
            defer { git_commit_free(parentCommit) }
            if let parentTreeID = git_commit_tree_id(parentCommit) {
                var pid = parentTreeID.pointee
                try check(git_tree_lookup(&oldTree, repo, &pid))
            }
        }
        defer { if oldTree != nil { git_tree_free(oldTree) } }

        return try pathCopies.withUnsafeMutableBufferPointer { buf in
            var diffOpts = git_diff_options()
            try check(git_diff_options_init(&diffOpts, UInt32(GIT_DIFF_OPTIONS_VERSION)))
            diffOpts.pathspec = git_strarray(strings: buf.baseAddress, count: buf.count)
            var diff: OpaquePointer?
            try check(git_diff_tree_to_tree(&diff, repo, oldTree, newTree, &diffOpts))
            defer { git_diff_free(diff) }
            return git_diff_num_deltas(diff) > 0
        }
    }

    private func makeLogEntry(repo: OpaquePointer?, oid: git_oid) throws -> LogEntry? {
        var oid = oid
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &oid))
        defer { git_commit_free(commit) }

        let sha = formatOID(&oid)

        // Tree SHA.
        var treeSHA = ""
        if let treeID = git_commit_tree_id(commit) {
            var tid = treeID.pointee
            treeSHA = formatOID(&tid)
        }

        // Parent SHAs.
        let parentCount = Int(git_commit_parentcount(commit))
        var parents: [String] = []
        parents.reserveCapacity(parentCount)
        for i in 0..<parentCount {
            if let pidPtr = git_commit_parent_id(commit, UInt32(i)) {
                var pid = pidPtr.pointee
                parents.append(formatOID(&pid))
            }
        }

        let author = git_commit_author(commit)?.pointee
        let committer = git_commit_committer(commit)?.pointee
        let messagePtr = git_commit_message(commit)
        let message = messagePtr.map { String(cString: $0) } ?? ""

        return LogEntry(
            sha: sha,
            shortSHA: String(sha.prefix(7)),
            treeSHA: treeSHA,
            parentSHAs: parents,
            authorName: author?.name.map { String(cString: $0) } ?? "",
            authorEmail: author?.email.map { String(cString: $0) } ?? "",
            authorTime: TimeInterval(author?.when.time ?? 0),
            authorOffsetMinutes: Int(author?.when.offset ?? 0),
            committerName: committer?.name.map { String(cString: $0) } ?? "",
            committerEmail: committer?.email.map { String(cString: $0) } ?? "",
            committerTime: TimeInterval(committer?.when.time ?? 0),
            committerOffsetMinutes: Int(committer?.when.offset ?? 0),
            message: message)
    }
}

// MARK: Formatting

extension LogEntry {

    /// Format an author/committer date the way real git's default
    /// `Date:` line does: `EEE MMM d HH:mm:ss yyyy ±HHMM`.
    public func formatDefaultDate(time: TimeInterval, offsetMinutes: Int) -> String {
        let date = Date(timeIntervalSince1970: time)
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60)
        let body = f.string(from: date)
        let sign = offsetMinutes >= 0 ? "+" : "-"
        let absMin = abs(offsetMinutes)
        let zone = String(format: "%@%02d%02d", sign, absMin / 60, absMin % 60)
        return "\(body) \(zone)"
    }

    /// ISO 8601 form for `%ai` / `%ci`: `2024-01-15 10:30:00 +0100`.
    public func formatISODate(time: TimeInterval, offsetMinutes: Int) -> String {
        let date = Date(timeIntervalSince1970: time)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: offsetMinutes * 60)
        let body = f.string(from: date)
        let sign = offsetMinutes >= 0 ? "+" : "-"
        let absMin = abs(offsetMinutes)
        let zone = String(format: "%@%02d%02d", sign, absMin / 60, absMin % 60)
        return "\(body) \(zone)"
    }

    /// Default `git log` block:
    ///   commit <sha>
    ///   [Merge: <p1> <p2>]
    ///   Author: <name> <<email>>
    ///   Date:   <ad>
    ///
    ///       <message indented 4 spaces>
    public func defaultFormat() -> String {
        var out = "commit \(sha)\n"
        if isMerge {
            let abbrev = parentSHAs.map { String($0.prefix(7)) }.joined(separator: " ")
            out += "Merge: \(abbrev)\n"
        }
        out += "Author: \(authorName) <\(authorEmail)>\n"
        out += "Date:   \(formatDefaultDate(time: authorTime, offsetMinutes: authorOffsetMinutes))\n"
        out += "\n"
        let stripped = message.hasSuffix("\n")
            ? String(message.dropLast())
            : message
        for line in stripped.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                out += "    \n"
            } else {
                out += "    \(line)\n"
            }
        }
        return out
    }

    /// `--oneline`: `<short-sha> <subject>`.
    public func onelineFormat() -> String {
        "\(shortSHA) \(subject)"
    }

    /// Resolve real-git format-string placeholders. Supports the
    /// commonly-scripted ones; unknown placeholders pass through
    /// verbatim.
    ///
    /// Two-letter placeholders (`%an`, `%ae`, `%ad`, `%ai`, `%at`,
    /// `%cn`, …) are matched first via a longest-match scan; if no
    /// match, single-letter codes (`%H`, `%h`, `%s`, `%b`, …) are tried.
    public func format(_ template: String) -> String {
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch != "%" || template.index(after: i) >= template.endIndex {
                out.append(ch)
                i = template.index(after: i)
                continue
            }
            // Try two-letter placeholder first.
            let after = template.index(after: i)
            let twoEnd = template.index(after, offsetBy: 2, limitedBy: template.endIndex)
            if let twoEnd, let two = expandPlaceholder(String(template[after..<twoEnd])) {
                out += two
                i = twoEnd
                continue
            }
            // Then single-letter.
            let oneEnd = template.index(after: after)
            if let one = expandPlaceholder(String(template[after..<oneEnd])) {
                out += one
                i = oneEnd
                continue
            }
            // Unknown — output the `%` verbatim and advance one char.
            out.append(ch)
            i = template.index(after: i)
        }
        return out
    }

    private func expandPlaceholder(_ key: String) -> String? {
        switch key {
        case "H": return sha
        case "h": return shortSHA
        case "T": return treeSHA
        case "P": return parentSHAs.joined(separator: " ")
        case "p": return parentSHAs.map { String($0.prefix(7)) }.joined(separator: " ")
        case "an": return authorName
        case "ae": return authorEmail
        case "ad": return formatDefaultDate(time: authorTime, offsetMinutes: authorOffsetMinutes)
        case "ai": return formatISODate(time: authorTime, offsetMinutes: authorOffsetMinutes)
        case "at": return String(Int(authorTime))
        case "cn": return committerName
        case "ce": return committerEmail
        case "cd": return formatDefaultDate(time: committerTime, offsetMinutes: committerOffsetMinutes)
        case "ci": return formatISODate(time: committerTime, offsetMinutes: committerOffsetMinutes)
        case "ct": return String(Int(committerTime))
        case "s": return subject
        case "b": return body
        case "B":
            return message.hasSuffix("\n") ? String(message.dropLast()) : message
        case "n": return "\n"
        case "%": return "%"
        default: return nil
        }
    }
}
