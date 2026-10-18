import Foundation
import CGitKit
import ForgeKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` merge operation
// (`GitKit/Repository+Merge.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off. `pull` / `pullRebase` live here in
// full: they compose other sandbox-aware GitClient operations (fetch +
// merge / rebase) rather than wrapping a single Repository call.
extension GitClient {

    /// Run a real-git-style merge of `theirRef` into HEAD.
    public func merge(
        ref theirRef: String,
        fastForward: FastForwardMode = .auto,
        message: String? = nil,
        author: GitSignature? = nil
    ) async throws -> MergeOutcome {
        try await withRepository {
            try $0.merge(
                ref: theirRef,
                fastForward: fastForward,
                message: message,
                author: author.core)
        }
    }

    /// Resume a paused merge after conflicts were resolved and staged.
    @discardableResult
    public func mergeContinue(
        message: String? = nil,
        author: GitSignature? = nil
    ) async throws -> Libgit2CommitDetails {
        let env = shellEnvironment()
        return try await withRepository {
            try $0.mergeContinue(
                message: message,
                author: author.core,
                env: env)
        }
    }

    /// The heads a merge of `heads` records, as `git merge` reduces
    /// them: those HEAD or another head already has drop out.
    public func mergeHeads(reducing heads: [String]) async throws -> MergeHeads {
        try await withRepository { try $0.mergeHeads(reducing: heads) }
    }

    /// What `git merge`'s message calls `spec`: `branch 'a'`, `tag 'v1'`, …
    public func mergeName(_ spec: String) async throws -> String {
        try await withRepository { $0.mergeName(spec) }
    }

    /// Merge `heads` (at least two, as ``mergeHeads(reducing:)`` leaves
    /// them) with git's octopus strategy.
    public func octopusMerge(
        heads: [String],
        noFastForward: Bool = false,
        message: String,
        author: GitSignature? = nil
    ) async throws -> OctopusMergeResult {
        let env = shellEnvironment()
        return try await withRepository {
            try $0.octopusMerge(
                heads: heads, noFastForward: noFastForward, message: message,
                author: author.core, env: env)
        }
    }

    /// One ref a fetch recorded in `FETCH_HEAD`, as git writes the line
    /// (`<oid>\t[not-for-merge]\t<description>`).
    public struct FetchHeadEntry: Sendable, Equatable {
        public let oid: String
        /// Whether the fetch marked it to be merged, as `git pull` does.
        public let isMerge: Bool
        /// What it is and where from: `branch 'main' of <url>`, as
        /// `git merge`'s message names it.
        public let description: String
    }

    /// `FETCH_HEAD`'s entries in the order the last fetch wrote them;
    /// empty when there is no `FETCH_HEAD`.
    public func fetchHeadEntries() async throws -> [FetchHeadEntry] {
        try await withRepository { repository in
            guard let gitDir = try repository.gitDir() else { return [] }
            let url = URL(fileURLWithPath: gitDir).appendingPathComponent("FETCH_HEAD")
            guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    guard fields.count == 3 else { return nil }
                    return FetchHeadEntry(
                        oid: String(fields[0]), isMerge: fields[1] != "not-for-merge",
                        description: String(fields[2]))
                }
        }
    }

    /// The branch HEAD names, born or not (`git symbolic-ref --short
    /// HEAD`); `nil` when HEAD is detached. GitKit keeps its repository
    /// handle to itself, so this opens its own.
    public func symbolicHeadBranch() async throws -> String? {
        try await withRepository { _ in
            var repo: OpaquePointer?
            var head: OpaquePointer?
            defer {
                git_reference_free(head)
                git_repository_free(repo)
            }
            try Self.check(git_repository_open_ext(&repo, workingDirectory.path, 0, nil))
            try Self.check(git_reference_lookup(&head, repo, "HEAD"))
            guard let target = git_reference_symbolic_target(head).map({ String(cString: $0) }),
                  target.hasPrefix("refs/heads/")
            else { return nil }
            return String(target.dropFirst("refs/heads/".count))
        }
    }

    /// Fetch then merge — `git pull <remote> [<branch>]`.
    ///
    /// Fetches `branch` from `remote` and merges what the fetch marked
    /// for merging in `FETCH_HEAD`, with git's message. Without a
    /// `branch`, it fetches the current branch's upstream
    /// (`branch.<name>.merge`) when `remote` is the branch's remote, and
    /// else the branch of the same name.
    public func pull(
        remote: String = "origin",
        branch: String? = nil,
        fastForward: FastForwardMode = .auto,
        message: String? = nil,
        author: GitSignature? = nil
    ) async throws -> MergeOutcome {
        let head = try await fetchForPull(remote: remote, branch: branch)
        var message = message
        if message == nil { message = try await pullMergeMessage(for: head, repository: remote) }
        return try await merge(
            ref: head.oid,
            fastForward: fastForward,
            message: message,
            author: author)
    }

    /// Fetch then rebase — `git pull --rebase <remote> [<branch>]`.
    /// Replays the local branch's commits since their merge-base with
    /// what was fetched (as for ``pull(remote:branch:fastForward:message:author:)``)
    /// on top of it.
    public func pullRebase(
        remote: String = "origin",
        branch: String? = nil,
        author: GitSignature? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> RebaseOutcome {
        let head = try await fetchForPull(remote: remote, branch: branch)
        return try await rebase(
            upstream: head.oid,
            author: author,
            progress: progress)
    }

    /// The merge commit message git writes for pulling `head` into the
    /// current branch: `Merge branch 'x' of <url>`, with ` into <branch>`
    /// unless `merge.suppressDest` (by default `main` and `master`)
    /// matches the branch. A `repository` that is a URL or path rather
    /// than a configured remote is named as typed (`../other`), and the
    /// repository itself (`.`) not at all, as git names them.
    public func pullMergeMessage(for head: FetchHeadEntry, repository: String? = nil) async throws -> String {
        try await pullMergeMessage(for: [head], repository: repository)
    }

    /// The merge commit message git writes for pulling `heads`: `Merge
    /// branches 'a' and 'b' of <url>`, with ` into <branch>` and the
    /// `repository` named as for one.
    public func pullMergeMessage(for heads: [FetchHeadEntry], repository: String? = nil) async throws -> String {
        let descriptions = heads.map(\.description)
        // The source the fetch wrote: a remote's URL as configured, else
        // the repository as given.
        var known: [String] = []
        let remotes = try await remoteList()
        if let repository {
            let source: String
            if remotes.contains(repository), let url = try await configGet("remote.\(repository).url") {
                source = url
            } else {
                source = repository
            }
            // As given, and as git's fetch writes it into FETCH_HEAD.
            known.append(source)
            if let written = Self.normalizingSource(MergeTitleEntry(name: nil, source: source)).source {
                known.append(written)
            }
        }
        var entries = Self.titleEntries(fetchedFrom: descriptions, knownSources: known)
        // A URL or path rather than a configured remote is named as typed.
        if let repository, !remotes.contains(repository) {
            entries = entries.map { MergeTitleEntry(name: $0.name, source: repository) }
        }
        // git's fmt-merge-msg reads each FETCH_HEAD line as git's fetch
        // writes it, cut at its first ` of ` whatever the URL holds.
        entries = entries.map { entry in
            let source = Self.normalizingSource(MergeTitleEntry(name: nil, source: entry.source)).source ?? "."
            return Self.fmtMergeMsgEntry([entry.name, source].compactMap { $0 }.joined(separator: " of "))
        }
        return try await mergeMessage(entries: entries, objects: heads.map(\.oid))
    }

    /// A FETCH_HEAD description as git's fmt-merge-msg reads it: what it
    /// names before the first ` of `, and the source after, or, with no
    /// ` of `, the source's own HEAD; `.` is this repository.
    static func fmtMergeMsgEntry(_ description: String) -> MergeTitleEntry {
        // This repository (`.`) is no source at all.
        func source(_ text: Substring) -> String? { text == "." ? nil : String(text) }
        guard let of = description.range(of: " of ") else {
            return MergeTitleEntry(name: nil, source: source(Substring(description)))
        }
        return MergeTitleEntry(name: String(description[..<of.lowerBound]), source: source(description[of.upperBound...]))
    }

    /// The merge commit message git writes (`fmt-merge-msg`) for heads
    /// that `FETCH_HEAD` or ``mergeName(_:)`` describe, with ` into
    /// <branch>` unless `merge.suppressDest` (by default `main` and
    /// `master`) matches the current branch. With the heads' `objects`,
    /// annotated tags' messages follow.
    public func mergeMessage(describing descriptions: [String], objects: [String] = []) async throws -> String {
        try await mergeMessage(entries: descriptions.map { MergeTitleEntry(name: $0, source: nil) }, objects: objects)
    }

    /// The merge commit message for heads `entries` names, as
    /// ``mergeMessage(describing:objects:)``.
    func mergeMessage(entries: [MergeTitleEntry], objects: [String] = []) async throws -> String {
        let origins = entries.map { entry in
            [entry.name, entry.source].compactMap { $0 }.joined(separator: " of ")
        }
        let subject = Self.mergeTitle(entries)
        let branch = try await currentBranch() ?? "HEAD"
        var patterns = ["main", "master"]
        var configured = false
        for entry in try await configList() where entry.name.lowercased() == "merge.suppressdest" {
            if !configured { patterns = []; configured = true }
            // An empty value clears the list, as in git.
            if entry.value.isEmpty { patterns = [] } else { patterns.append(entry.value) }
        }
        let title = patterns.contains(where: { Self.glob($0, matches: branch) })
            ? subject : subject + " into " + branch
        // Annotated tags' messages follow, as fmt_merge_msg_sigs adds
        // them (signatures left out): one alone, several each under a
        // comment naming it, an empty message too.
        var tags: [(origin: String, message: String)] = []
        for (origin, object) in zip(origins, objects) where origin.hasPrefix("tag '") {
            if let message = try await annotatedTagMessage(object) { tags.append((origin, message)) }
        }
        guard tags.count > 1 else {
            guard let message = tags.first?.message, !message.isEmpty else { return title }
            return title + "\n\n" + message
        }
        let commentSetting = try await configList()
            .last { ["core.commentchar", "core.commentstring"].contains($0.name.lowercased()) }?.value
        let comment = commentSetting.flatMap { $0.isEmpty || $0.lowercased() == "auto" ? nil : $0 } ?? "#"
        // Sections a blank line apart, each its comment then its message.
        let sections = tags.map { "\(comment) \($0.origin)\n" + ($0.message.isEmpty ? "" : $0.message + "\n") }
        var text = title + "\n\n" + sections.joined(separator: "\n")
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    /// The message of annotated tag object `oid`, without a signature
    /// and trailing whitespace; `nil` when `oid` is no tag object.
    func annotatedTagMessage(_ oid: String) async throws -> String? {
        try await withRepository { _ in
            var repo: OpaquePointer?
            var tag: OpaquePointer?
            defer {
                git_tag_free(tag)
                git_repository_free(repo)
            }
            try Self.check(git_repository_open_ext(&repo, workingDirectory.path, 0, nil))
            var id = git_oid()
            guard git_oid_fromstr(&id, oid) == 0, git_tag_lookup(&tag, repo, &id) == 0,
                  let text = git_tag_message(tag).map({ String(cString: $0) })
            else { return nil }
            var message = Substring(text)
            for marker in ["-----BEGIN PGP SIGNATURE-----", "-----BEGIN SSH SIGNATURE-----",
                           "-----BEGIN SIGNED MESSAGE-----"] {
                if let start = message.range(of: "\n" + marker) ?? (message.hasPrefix(marker) ? message.range(of: marker) : nil) {
                    message = message[..<start.lowerBound]
                }
            }
            while let last = message.last, last.isWhitespace { message = message.dropLast() }
            return String(message)
        }
    }

    /// `git pull`'s fetch for one branch, and what it marked to merge.
    private func fetchForPull(remote: String, branch: String?) async throws -> FetchHeadEntry {
        var refspec = branch
        if refspec == nil, let current = try await currentBranch() {
            if try await configGet("branch.\(current).remote") == remote,
               let merge = try await configGet("branch.\(current).merge") {
                refspec = merge
            } else {
                refspec = current
            }
        }
        try await fetch(remote: remote, refspecs: [refspec ?? "HEAD"], depth: nil)
        guard let head = try await fetchHeadEntries().first(where: \.isMerge) else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "There are no candidates for merging among the refs that you just fetched.")
        }
        return head
    }

    /// `Merge …` for heads that `FETCH_HEAD` describes, grouped as git's
    /// `fmt-merge-msg` groups them: by where they came from (`of <url>`,
    /// or nothing for this repository), each a commit named by itself in
    /// a group of its own, groups in the order first seen and joined by
    /// `; `; within one, branches, remote-tracking branches, tags and
    /// other refs (as commits), each kind joined as `'a', 'b' and 'c'`.
    static func mergeTitle(_ entries: [MergeTitleEntry]) -> String {
        struct Group {
            let source: String?
            /// Whether the source's own HEAD is among the heads.
            var head = false
            var branches: [String] = [], remoteBranches: [String] = [], tags: [String] = [], commits: [String] = []
        }
        var groups: [Group] = []
        for entry in entries {
            let source = entry.source
            guard let name = entry.name else {
                // A source's own HEAD leads its group as `HEAD`, or names
                // the source alone.
                if let index = groups.firstIndex(where: { $0.source == source && $0.commits.isEmpty }) {
                    groups[index].head = true
                } else {
                    groups.append(Group(source: source, head: true))
                }
                continue
            }
            var line = Substring(name)
            // A commit named by itself has a group of its own.
            let isCommit = source == nil && line.hasPrefix("commit ")
            var index = groups.firstIndex { $0.source == source && (source != nil || $0.commits.isEmpty) }
            if index == nil || isCommit {
                groups.append(Group(source: source))
                index = groups.count - 1
            }
            // Any other ref (`'refs/x' of <url>`) is named as a commit.
            for (prefix, keyPath) in [("branch ", \Group.branches), ("remote-tracking branch ", \Group.remoteBranches),
                                      ("tag ", \Group.tags), ("commit ", \Group.commits)] where line.hasPrefix(prefix) {
                groups[index!][keyPath: keyPath].append(String(line.dropFirst(prefix.count)))
                line = ""
            }
            if !line.isEmpty { groups[index!].commits.append(String(line)) }
        }
        func joined(_ singular: String, _ plural: String, _ names: [String]) -> String? {
            guard let last = names.last else { return nil }
            if names.count == 1 { return singular + " " + last }
            return plural + " " + names.dropLast().joined(separator: ", ") + " and " + last
        }
        let parts = groups.map { group -> String in
            var kinds = [joined("branch", "branches", group.branches),
                         joined("remote-tracking branch", "remote-tracking branches", group.remoteBranches),
                         joined("tag", "tags", group.tags),
                         joined("commit", "commits", group.commits)].compactMap { $0 }
            if group.head {
                if kinds.isEmpty { return group.source ?? "HEAD" }
                kinds.insert("HEAD", at: 0)
            }
            guard let source = group.source else { return kinds.joined(separator: ", ") }
            return kinds.joined(separator: ", ") + " of " + source
        }
        return "Merge " + parts.joined(separator: "; ")
    }

    /// One head as a merge message names it: `name` (`branch 'a'`,
    /// `tag 'v1'`, …), `nil` for a source's own HEAD; and where it came
    /// from, `nil` for this repository.
    public struct MergeTitleEntry: Sendable, Equatable {
        public var name: String?
        public var source: String?
        public init(name: String?, source: String?) {
            self.name = name
            self.source = source
        }
    }

    /// FETCH_HEAD's descriptions from one fetch, split into what each
    /// names and the source they share: `<name> of <source>`, or the
    /// source alone for its HEAD. The source is one of `knownSources`
    /// that fits every description, else the longest that does, read off
    /// the descriptions themselves (a ref name holds no space, so a name
    /// ends at the first `' of `); a URL or path may hold anything.
    static func titleEntries(fetchedFrom descriptions: [String], knownSources: [String] = []) -> [MergeTitleEntry] {
        func fits(_ source: String) -> Bool {
            descriptions.allSatisfy { $0 == source || $0.hasSuffix("' of " + source) }
        }
        var source = knownSources.first(where: fits)
        if source == nil {
            var candidates: [String] = descriptions.compactMap { description in
                description.range(of: "' of ").map { String(description[$0.upperBound...]) }
            }
            // A lone description is its source only when it names nothing.
            if descriptions.count > 1 || candidates.isEmpty { candidates += descriptions }
            source = candidates.filter(fits).max { $0.count < $1.count }
        }
        return descriptions.map { description in
            guard let source else { return MergeTitleEntry(name: description, source: nil) }
            if description == source { return MergeTitleEntry(name: nil, source: source) }
            return MergeTitleEntry(name: String(description.dropLast(source.count + 4)), source: source)
        }
    }

    /// `entry` with its source as git's fetch writes it: without trailing
    /// slashes, then without a trailing `.git`; this repository (`.`) is
    /// no source at all.
    static func normalizingSource(_ entry: MergeTitleEntry) -> MergeTitleEntry {
        guard var url = entry.source.map({ Substring($0) }) else { return entry }
        while url.count > 1, url.hasSuffix("/") { url = url.dropLast() }
        if url.count > 5, url.hasSuffix(".git") { url = url.dropLast(4) }
        return MergeTitleEntry(name: entry.name, source: url == "." ? nil : String(url))
    }

    /// wildmatch's named character classes, over ASCII bytes as git has them.
    static let characterClasses: [String: @Sendable (UInt8) -> Bool] = [
        "alnum": { isASCIILetter($0) || (0x30...0x39).contains($0) },
        "alpha": { isASCIILetter($0) },
        "blank": { $0 == 0x20 || $0 == 0x09 },
        "cntrl": { $0 < 32 || $0 == 127 },
        "digit": { (0x30...0x39).contains($0) },
        "graph": { $0 > 32 && $0 < 127 },
        "lower": { (0x61...0x7a).contains($0) },
        "print": { $0 >= 32 && $0 < 127 },
        "punct": { $0 > 32 && $0 < 127 && !isASCIILetter($0) && !(0x30...0x39).contains($0) },
        "space": { [0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d].contains($0) },
        "upper": { (0x41...0x5a).contains($0) },
        "xdigit": { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) },
    ]

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte)
    }

    /// Whether glob `pattern` matches `text`, as git's wildmatch does
    /// for a branch name (with WM_PATHNAME), over UTF-8 bytes: `*`, `**`, `?`, bracket expressions
    /// (`[tw]`, `[a-z]`, `[!x]`, `[^x]`, `[[:alpha:]]`) and `\\`
    /// escaping the next byte.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let pattern = Array(pattern.utf8), text = Array(text.utf8)
        let (star, question, open, close, backslash, colon, dash, bang, caret): (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0x2a, 0x3f, 0x5b, 0x5d, 0x5c, 0x3a, 0x2d, 0x21, 0x5e)
        let slash: UInt8 = 0x2f
        /// The end of the bracket expression opening at `p` and whether
        /// it matches `c`, or `nil` when it is malformed (it then matches
        /// nothing, as in wildmatch).
        func bracket(_ p: Int, _ c: UInt8) -> (end: Int, matches: Bool)? {
            var i = p + 1
            let negated = i < pattern.count && (pattern[i] == bang || pattern[i] == caret)
            if negated { i += 1 }
            var matched = false
            var first = true
            while i < pattern.count, pattern[i] != close || first {
                first = false
                // A named class (`[:alpha:]`); one git doesn't know
                // matches nothing.
                if pattern[i] == open, i + 1 < pattern.count, pattern[i + 1] == colon {
                    guard let end = (i + 2..<pattern.count).first(where: {
                        pattern[$0] == colon && $0 + 1 < pattern.count && pattern[$0 + 1] == close
                    }), let test = Self.characterClasses[String(decoding: pattern[(i + 2)..<end], as: UTF8.self)]
                    else { return nil }
                    if test(c) { matched = true }
                    i = end + 2
                    continue
                }
                var low = pattern[i]
                if low == backslash, i + 1 < pattern.count { i += 1; low = pattern[i] }
                if i + 2 < pattern.count, pattern[i + 1] == dash, pattern[i + 2] != close {
                    var high = pattern[i + 2]
                    i += 2
                    if high == backslash, i + 1 < pattern.count { i += 1; high = pattern[i] }
                    if low <= c && c <= high { matched = true }
                } else if low == c {
                    matched = true
                }
                i += 1
            }
            guard i < pattern.count else { return nil }
            return (i + 1, matched != negated)
        }
        func match(_ p: Int, _ t: Int) -> Bool {
            if p == pattern.count { return t == text.count }
            switch pattern[p] {
            case star:
                // `**` between slashes (or the ends) crosses them, `**/`
                // matching no directory too; any other `*` stays within
                // a component (WM_PATHNAME, as dest_suppressed uses).
                // A run of stars counts as one.
                var skip = p + 1
                while skip < pattern.count, pattern[skip] == star { skip += 1 }
                if skip - p > 1, p == 0 || pattern[p - 1] == slash,
                   skip == pattern.count || pattern[skip] == slash {
                    if skip < pattern.count, match(skip + 1, t) { return true }
                    return (t...text.count).contains { match(skip, $0) }
                }
                var end = t
                while end < text.count, text[end] != slash { end += 1 }
                return (t...end).contains { match(skip, $0) }
            case question: return t < text.count && text[t] != slash && match(p + 1, t + 1)
            case open:
                guard t < text.count, text[t] != slash,
                      let (end, matches) = bracket(p, text[t]) else { return false }
                return matches && match(end, t + 1)
            case backslash where p + 1 < pattern.count:
                return t < text.count && text[t] == pattern[p + 1] && match(p + 2, t + 1)
            case let c: return t < text.count && text[t] == c && match(p + 1, t + 1)
            }
        }
        return match(0, 0)
    }
}
