#if !os(Android)  // argv-parsing test; ArgumentParser trips the Android explicit-module scanner
import Foundation
import ShellKit
import Testing
@testable import FdCommand
@testable import FdKit

@Suite struct FdExecutableTests {

    /// Run the executable inside a fresh `Shell` bound to a temp
    /// working directory. Captures stdout/stderr.
    private func run(_ argv: [String],
                     in tree: [String: String] = [:],
                     stdin input: String = "")
    async throws -> (stdout: String, stderr: String, exit: Int32, root: URL) {
        let root = try makeTree(tree)
        let env = Environment(
            variables: ProcessInfo.processInfo.environment,
            workingDirectory: root.path)
        var shell = Shell(environment: env)
        shell.stdin = .string(input)
        let stdoutSink = OutputSink()
        let stderrSink = OutputSink()
        shell.stdout = stdoutSink
        shell.stderr = stderrSink
        let exit = try await Shell.$current.withValue(shell) {
            try await FdExecutable.run(
                argv: argv,
                stdin: shell.stdin,
                stdout: stdoutSink,
                stderr: stderrSink)
        }
        stdoutSink.finish()
        stderrSink.finish()
        let outString = await stdoutSink.readAllString()
        let errString = await stderrSink.readAllString()
        return (outString, errString, exit, root)
    }

    private func makeTree(_ tree: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fd-cli-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        for (path, content) in tree {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        return root
    }

    // MARK: - Basic operation

    @Test func noPatternListsEverything() async throws {
        let r = try await run(["--color=never"], in: [
            "a.txt":     "x",
            "sub/b.txt": "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("a.txt"))
        #expect(r.stdout.contains("sub/b.txt"))
    }

    @Test func exit1WhenNoMatch() async throws {
        let r = try await run(["--color=never", "nothere"], in: [
            "a.txt": "x",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 1)
    }

    @Test func regexAgainstBasename() async throws {
        let r = try await run(["--color=never", "\\.swift$"], in: [
            "a.swift": "x",
            "b.md":    "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.swift"))
        #expect(!r.stdout.contains("b.md"))
    }

    @Test func fixedStringsEscape() async throws {
        let r = try await run(["-F", "--color=never", "a.b.c"], in: [
            "a.b.c.txt": "x",
            "axbyc.txt": "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.b.c.txt"))
        #expect(!r.stdout.contains("axbyc.txt"))
    }

    // MARK: - User-asked-for flag combo

    @Test func combinedFlagsFromUserRequest() async throws {
        // fd --glob --color=never --hidden --no-require-git
        //   --max-results 3 [--full-path] -- <pattern> <searchPath>
        let r = try await run([
            "--glob", "--color=never", "--hidden", "--no-require-git",
            "--max-results", "3",
            "--", "*", ".",
        ], in: [
            ".hidden":   "x",
            "a.txt":     "y",
            "b.md":      "z",
            "c.swift":   "q",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 3)
        // The hidden file should appear once `--hidden` is on; the cap
        // limits us to three of the four.
        #expect(r.exit == 0)
    }

    @Test func combinedFlagsWithFullPath() async throws {
        let r = try await run([
            "--glob", "--color=never", "--hidden", "--no-require-git",
            "--max-results", "10", "--full-path",
            "--", "*sub*", ".",
        ], in: [
            "a.txt":         "x",
            "sub/b.txt":     "y",
            "sub/nested/c":  "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        for line in lines {
            #expect(line.contains("sub"),
                    "unexpected non-sub line: \(line)")
        }
        #expect(!lines.isEmpty)
    }

    // MARK: - Ignore rules

    @Test func gitignoreRespectedByDefault() async throws {
        let r = try await run(["--color=never"], in: [
            ".git/HEAD":  "ref: refs/heads/main\n",
            ".gitignore": "*.log\n",
            "a.log":      "x",
            "a.txt":      "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(!r.stdout.contains("a.log"))
    }

    @Test func noIgnoreShowsEverything() async throws {
        let r = try await run(["--color=never", "--no-ignore"], in: [
            ".git/HEAD":  "ref: refs/heads/main\n",
            ".gitignore": "*.log\n",
            "a.log":      "x",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.log"))
    }

    @Test func fdignoreRespectedByDefault() async throws {
        let r = try await run(["--color=never"], in: [
            ".git/HEAD": "ref: refs/heads/main\n",
            ".fdignore": "private/\n",
            "private/secret.txt": "x",
            "public/open.txt":    "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("public/open.txt"))
        #expect(!r.stdout.contains("private/"))
        #expect(!r.stdout.contains("private/secret.txt"))
    }

    @Test func noRequireGitAppliesGitignoreOutsideRepo() async throws {
        let r = try await run(["--color=never", "--no-require-git"], in: [
            // No .git here — under the default require-git semantics
            // the .gitignore would be ignored.
            ".gitignore": "*.log\n",
            "a.log":      "x",
            "a.txt":      "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(!r.stdout.contains("a.log"))
    }

    // MARK: - Filters

    @Test func typeFilterFile() async throws {
        let r = try await run(["--color=never", "-t", "f"], in: [
            "a.txt":     "x",
            "sub/b.txt": "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        for line in lines {
            #expect(!line.hasSuffix("/"),
                    "directory leaked into file-only listing: \(line)")
        }
    }

    @Test func typeFilterDirectory() async throws {
        let r = try await run(["--color=never", "-t", "d"], in: [
            "a.txt":         "x",
            "sub/b.txt":     "y",
            "more/c.txt":    "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(line.hasSuffix("/"),
                    "non-directory leaked: \(line)")
        }
    }

    @Test func extensionFilter() async throws {
        let r = try await run(["--color=never", "-e", "swift"], in: [
            "a.swift": "x",
            "b.txt":   "y",
            "c.swift": "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.swift"))
        #expect(r.stdout.contains("c.swift"))
        #expect(!r.stdout.contains("b.txt"))
    }

    @Test func excludePattern() async throws {
        let r = try await run(["--color=never", "-E", "*.md"], in: [
            "a.txt": "x",
            "b.md":  "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(!r.stdout.contains("b.md"))
    }

    @Test func sizeFilterAtLeast() async throws {
        // Generate one small file (~1 byte) and one large (~2k).
        let big = String(repeating: "a", count: 2048)
        let r = try await run(["--color=never", "-t", "f", "-S", "+1k"], in: [
            "small.txt": "a",
            "big.txt":   big,
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("big.txt"))
        #expect(!r.stdout.contains("small.txt"))
    }

    // MARK: - Depth

    @Test func maxDepthLimitsTraversal() async throws {
        let r = try await run(["--color=never", "-d", "1"], in: [
            "a.txt":        "x",
            "sub/b.txt":    "y",
            "sub/nested/c": "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(r.stdout.contains("sub/"))
        #expect(!r.stdout.contains("sub/b.txt"))
    }

    @Test func minDepth() async throws {
        let r = try await run(["--color=never", "--min-depth=2"], in: [
            "a.txt":        "x",
            "sub/b.txt":    "y",
            "sub/nested/c": "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(!r.stdout.contains("a.txt"))
        #expect(r.stdout.contains("sub/b.txt"))
    }

    @Test func exactDepthAliasMinAndMax() async throws {
        let r = try await run(["--color=never", "--exact-depth=1"], in: [
            "a.txt":     "x",
            "sub/b.txt": "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(r.stdout.contains("sub/"))
        #expect(!r.stdout.contains("sub/b.txt"))
    }

    // MARK: - Output

    @Test func maxResultsCaps() async throws {
        let r = try await run(["--color=never", "--max-results=2"], in: [
            "a": "1", "b": "2", "c": "3", "d": "4",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 2)
    }

    @Test func dashOneIsMaxResultsOne() async throws {
        let r = try await run(["--color=never", "-1"], in: [
            "a": "1", "b": "2", "c": "3",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(lines.count == 1)
    }

    @Test func print0EmitsNullTerminator() async throws {
        let r = try await run(["--color=never", "--print0", "-t", "f"], in: [
            "a.txt": "x",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt\0"))
        #expect(!r.stdout.contains("a.txt\n"))
    }

    @Test func absolutePathFlag() async throws {
        let r = try await run(["--color=never", "-a", "-t", "f"], in: [
            "a.txt": "x",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        // Every line should be absolute. On POSIX that means a leading
        // `/`; on Windows the toolchain emits `C:/…`-style paths.
        // Cross-platform: assert each path contains the absolute temp
        // root so we know `-a` actually emitted a rooted path rather
        // than something relative to cwd.
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(!lines.isEmpty)
        let rootStandardized = r.root.standardizedFileURL.path
        for line in lines {
            #expect(line.contains(rootStandardized),
                    "line does not contain the absolute root \(rootStandardized): \(line)")
            #expect(!line.hasPrefix("./"),
                    "absolute-path line has stale ./ prefix: \(line)")
        }
    }

    @Test func absolutePathFoldsToVirtualUnderPathMapping() async throws {
        // Under a path-mapped sandbox (SwiftBash --sandbox, #83) the
        // shell's CWD is a VIRTUAL spelling; `Shell.resolve` /
        // `Shell.currentDirectory` translate it to the mapped host
        // dir for the walk, and `-a` output folds the host paths back
        // so the embedder's disk layout never reaches the script.
        let root = try makeTree(["found.txt": "x", "sub/inner.txt": "y"])
        defer { try? FileManager.default.removeItem(at: root) }
        let mapping = PathMapping(mounts: [
            .init(virtual: "/work", host: root.path)
        ])
        var env = Environment()
        env.workingDirectory = "/work"
        let shell = Shell(environment: env)
        shell.sandbox = .confined(to: mapping, home: "/work")
        let stdoutSink = OutputSink()
        let stderrSink = OutputSink()
        shell.stdout = stdoutSink
        shell.stderr = stderrSink
        let exit = try await Shell.$current.withValue(shell) {
            try await FdExecutable.run(
                argv: ["--color=never", "-a", "-t", "f"],
                stdin: shell.stdin,
                stdout: stdoutSink,
                stderr: stderrSink)
        }
        stdoutSink.finish()
        stderrSink.finish()
        let stdout = await stdoutSink.readAllString()
        #expect(exit == 0)
        let lines = Set(stdout.split(separator: "\n").map(String.init))
        #expect(lines == ["/work/found.txt", "/work/sub/inner.txt"])
        #expect(!stdout.contains(root.path))
    }

    @Test func stripCwdPrefix() async throws {
        let r = try await run(["--color=never", "--strip-cwd-prefix", "-t", "f"], in: [
            "a.txt": "x",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        // No path should start with `./`.
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        for line in lines {
            #expect(!line.hasPrefix("./"),
                    "stale ./ prefix on line: \(line)")
        }
    }

    @Test func hiddenFlagIncludesDottedEntries() async throws {
        let r = try await run(["--color=never", "--hidden"], in: [
            ".secret": "x",
            "visible": "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains(".secret"))
        #expect(r.stdout.contains("visible"))
    }

    @Test func quietExitOnlyNoOutput() async throws {
        let r = try await run(["--color=never", "-q", "a"], in: [
            "a.txt": "x",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.isEmpty)
    }

    // MARK: - Pattern flavors

    @Test func globOnlyMatchesNamedSubset() async throws {
        let r = try await run(["--glob", "--color=never", "*.swift"], in: [
            "a.swift":     "x",
            "b.md":        "y",
            "sub/c.swift": "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.swift"))
        #expect(r.stdout.contains("sub/c.swift"))
        #expect(!r.stdout.contains("b.md"))
    }

    @Test func fullPathMatchesAgainstRelativePath() async throws {
        let r = try await run(
            ["--glob", "--color=never", "--full-path", "*/nested/*"],
            in: [
                "a.txt":             "x",
                "sub/b.txt":         "y",
                "sub/nested/c.txt":  "z",
            ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        for line in lines {
            #expect(line.contains("nested"))
        }
        #expect(lines.contains(where: { $0.hasSuffix("c.txt") }))
    }

    // MARK: - Error cases

    @Test func missingPathExitsWithError() async throws {
        let r = try await run(["--color=never", "pattern", "no-such-dir-xyz"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 2)
        #expect(r.stderr.contains("no-such-dir-xyz"))
    }

    @Test func invalidRegexExitsWithError() async throws {
        let r = try await run(["--color=never", "("])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 2)
    }

    @Test func helpExits0() async throws {
        let r = try await run(["--help"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("fd [OPTIONS]"))
    }

    @Test func versionExits0() async throws {
        let r = try await run(["--version"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("fd"))
    }

    @Test func parsesFdCommandViaArgumentParser() throws {
        let cmd = try FdCommand.parse(["--glob", "*.txt", "."])
        #expect(cmd.rawArgv == ["--glob", "*.txt", "."])
    }

    // MARK: - Regression tests for PR review feedback

    /// `fd --search-path PATH` (no positional pattern) must scope the
    /// listing to PATH, not consume PATH as the pattern. Regression:
    /// PR #38 review — the parser was appending `--search-path`
    /// values into the generic positional list, so the first one was
    /// being picked up as PATTERN and dropped from the root list.
    @Test func searchPathIsTreatedAsRoot() async throws {
        let r = try await run([
            "--color=never", "--search-path", "sub",
        ], in: [
            "a.txt":     "x",
            "sub/b.txt": "y",
            "sub/c.txt": "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
        // Every emitted line should live under `sub/`.
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(line.hasPrefix("sub/") || line == "sub",
                    "unexpected listing outside sub: \(line)")
        }
        #expect(lines.contains(where: { $0.hasSuffix("b.txt") }))
        #expect(lines.contains(where: { $0.hasSuffix("c.txt") }))
    }

    /// Combining a real pattern with `--search-path` should still
    /// route the pattern to PATTERN and the flag value to the roots.
    @Test func searchPathCoexistsWithPattern() async throws {
        let r = try await run([
            "--color=never", "--search-path", "sub", "\\.txt$",
        ], in: [
            "a.txt":     "x",
            "sub/b.txt": "y",
            "sub/c.md":  "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("sub/b.txt"))
        #expect(!r.stdout.contains("sub/c.md"))
        // The `a.txt` at root must not appear — only `sub/` is searched.
        #expect(!r.stdout.contains("\na.txt"))
    }

    /// Unsigned `--size N` must filter for files *exactly* that size,
    /// not "at least N". Regression: PR #38 review — the default
    /// direction was `.atLeast`, so `--size 10` was treated as `≥10`
    /// and silently broadened scripts that wanted exact-size matches.
    @Test func sizeFilterUnsignedIsExact() async throws {
        // Three files: 1B, 5B, 10B. `-S 5b` should match only the
        // middle one.
        let r = try await run(
            ["--color=never", "-t", "f", "-S", "5b"],
            in: [
                "small.txt":  "a",
                "medium.txt": "aaaaa",
                "big.txt":    "aaaaaaaaaa",
            ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("medium.txt"))
        #expect(!r.stdout.contains("small.txt"))
        #expect(!r.stdout.contains("big.txt"))
    }

    /// `-S -N` keeps the at-most semantics — verify the signed forms
    /// still work after the default flipped to `.exactly`.
    @Test func sizeFilterAtMost() async throws {
        let r = try await run(
            ["--color=never", "-t", "f", "-S", "-2b"],
            in: [
                "tiny.txt":   "a",
                "medium.txt": "aaaaa",
            ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("tiny.txt"))
        #expect(!r.stdout.contains("medium.txt"))
    }

    /// `--color never` (space-separated value) must parse as the
    /// `.never` choice. Regression: PR #38 review — the value-side of
    /// the long flag was hard-coded to `"always"` when inline was
    /// absent, so `--color never` ended up enabling color and
    /// leaking `never` into the positional list.
    @Test func colorAcceptsSpaceSeparatedValue() async throws {
        let r = try await run(["--color", "never"], in: [
            "a.txt": "x",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        // No ANSI escape should leak through with `--color never`.
        #expect(!r.stdout.contains("\u{1B}["),
                "ANSI escape in --color never output: \(r.stdout)")
        // `never` must NOT have been consumed as a positional path.
        #expect(!r.stderr.contains("never"))
    }

    /// Unknown `--color` values must be rejected with an argument
    /// error. Regression: PR #38 review — typos like `--color nope`
    /// previously fell through to `.auto` silently.
    @Test func colorRejectsUnknownValue() async throws {
        let r = try await run(["--color", "nope"], in: [
            "a.txt": "x",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 2)
        #expect(r.stderr.contains("--color"))
    }
}

#endif  // !os(Android)
