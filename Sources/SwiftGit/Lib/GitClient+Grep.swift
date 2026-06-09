import Foundation
import ForgeKit
import CGitKit

extension GitClient {

    /// One line in a `git grep` match. Mirrors what `git grep` prints
    /// in its `<path>:<line>:<text>` mode — the lib stays
    /// format-agnostic so callers can render line-only / files-only /
    /// count modes themselves.
    public struct GrepMatch: Sendable, Equatable {
        /// Repo-relative path of the file the match is in.
        public let path: String
        /// 1-indexed line number, matching `grep -n` semantics.
        public let lineNumber: Int
        /// The matched line, no trailing newline.
        public let line: String

        public init(path: String, lineNumber: Int, line: String) {
            self.path = path
            self.lineNumber = lineNumber
            self.line = line
        }
    }

    /// Search files in the repo for `pattern` and return one
    /// ``GrepMatch`` per matched line. Backs `git grep`. The default
    /// set of files searched is the tracked working-tree files (same
    /// as real `git grep` without flags). `.gitignore`'d paths are
    /// skipped automatically — they aren't in the index, so they
    /// never enter the candidate list.
    ///
    /// - Parameter pattern: Regex evaluated by `NSRegularExpression`.
    /// - Parameter options: Regex options (e.g. `.caseInsensitive`).
    /// - Parameter pathFilters: Optional path-spec globs. Each
    ///     candidate is kept when any filter matches either the full
    ///     repo-relative path or just the basename — that covers both
    ///     `src/foo.swift` and `*.swift` styles. Empty = no filter.
    /// - Parameter includeUntracked: When true, also include untracked
    ///     files that aren't `.gitignore`'d. Matches
    ///     `git grep --untracked`.
    /// - Returns: Matches in walk order (tracked files first, then
    ///     optional untracked). Empty array when nothing matched.
    public func grep(
        pattern: String,
        options: NSRegularExpression.Options = [],
        pathFilters: [String] = [],
        includeUntracked: Bool = false
    ) async throws -> [GrepMatch] {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let workdir = workingDirectory

        var paths = try await indexedPaths()
        if includeUntracked {
            let report = try await status()
            for entry in report.entries where entry.isUntracked && !entry.isIgnored {
                paths.append(entry.path)
            }
        }

        if !pathFilters.isEmpty {
            paths = paths.filter { Self.path($0, matchesAny: pathFilters) }
        }

        var matches: [GrepMatch] = []
        for relPath in paths {
            try Task.checkCancellation()
            let absPath = workdir.appendingPathComponent(relPath).path
            guard let data = FileManager.default.contents(atPath: absPath),
                  let content = String(data: data, encoding: .utf8) else {
                // Skip binary files / unreadable paths. Real `git grep`
                // also skips binaries by default (uses `-I` semantics)
                // unless `-a` is passed; we just drop them silently.
                continue
            }
            let lines = content.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil {
                    matches.append(GrepMatch(
                        path: relPath,
                        lineNumber: index + 1,
                        line: line))
                }
            }
        }
        return matches
    }

    /// Glob-match the candidate against each filter, testing either
    /// the full repo-relative path or just the basename so the user
    /// can write `*.swift` and have it hit `src/foo.swift` without
    /// spelling the leading globs out. Pure Swift — no `fnmatch(3)`
    /// shellout — so it works on Windows where libc doesn't ship one.
    /// Semantics match `fnmatch(pattern, name, 0)`: `*` matches any
    /// run of characters (including `/`), `?` matches one.
    private static func path(_ candidate: String, matchesAny filters: [String]) -> Bool {
        let basename = (candidate as NSString).lastPathComponent
        for pattern in filters {
            if glob(pattern: pattern, name: candidate) { return true }
            if glob(pattern: pattern, name: basename)  { return true }
        }
        return false
    }

    /// Recursive `*`/`?` glob matcher with memoisation. Same shape as
    /// `fnmatch(pattern, name, 0)` — `*` matches any sequence, `?`
    /// matches any single character, everything else is literal.
    /// Bracket expressions are not supported (real `git grep` doesn't
    /// need them for the pathspecs we accept).
    static func glob(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        var memo: [[Bool?]] = Array(
            repeating: Array(repeating: nil, count: n.count + 1),
            count: p.count + 1)
        func match(_ i: Int, _ j: Int) -> Bool {
            if let cached = memo[i][j] { return cached }
            let result: Bool
            if i == p.count {
                result = j == n.count
            } else if p[i] == "*" {
                result = match(i + 1, j) || (j < n.count && match(i, j + 1))
            } else if j < n.count && (p[i] == "?" || p[i] == n[j]) {
                result = match(i + 1, j + 1)
            } else {
                result = false
            }
            memo[i][j] = result
            return result
        }
        return match(0, 0)
    }
}
