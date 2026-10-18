import Foundation
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
        if message == nil { message = try await pullMergeMessage(for: head) }
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
    /// matches the branch.
    public func pullMergeMessage(for head: FetchHeadEntry) async throws -> String {
        let subject = "Merge " + Self.describingURLAsGit(head.description)
        let branch = try await currentBranch() ?? "HEAD"
        var patterns = ["main", "master"]
        var configured = false
        for entry in try await configList() where entry.name.lowercased() == "merge.suppressdest" {
            if !configured { patterns = []; configured = true }
            // An empty value clears the list, as in git.
            if entry.value.isEmpty { patterns = [] } else { patterns.append(entry.value) }
        }
        if patterns.contains(where: { Self.glob($0, matches: branch) }) { return subject }
        return subject + " into " + branch
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

    /// A FETCH_HEAD description with its URL as git's fetch writes it:
    /// without trailing slashes, then without a trailing `.git`
    /// (`branch 'x' of ../other.git` becomes `branch 'x' of ../other`).
    /// The URL follows `' of `, as no ref name holds a space, or is the
    /// whole description for a remote's `HEAD`.
    static func describingURLAsGit(_ description: String) -> String {
        let prefix: Substring
        var url: Substring
        if let of = description.range(of: "' of ") {
            prefix = description[..<of.upperBound]
            url = description[of.upperBound...]
        } else {
            prefix = ""
            url = Substring(description)
        }
        while url.count > 1, url.hasSuffix("/") { url = url.dropLast() }
        if url.count > 5, url.hasSuffix(".git") { url = url.dropLast(4) }
        return String(prefix + url)
    }

    /// Whether glob `pattern` (`*`, `?`) matches `text`.
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let pattern = Array(pattern), text = Array(text)
        func match(_ p: Int, _ t: Int) -> Bool {
            if p == pattern.count { return t == text.count }
            switch pattern[p] {
            case "*": return (t...text.count).contains { match(p + 1, $0) }
            case "?": return t < text.count && match(p + 1, t + 1)
            case let c: return t < text.count && text[t] == c && match(p + 1, t + 1)
            }
        }
        return match(0, 0)
    }
}
