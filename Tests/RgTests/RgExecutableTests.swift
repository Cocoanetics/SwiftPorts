#if !os(Android)  // argv-parsing test; ArgumentParser trips the Android explicit-module scanner
import Foundation
import ShellKit
import Testing
@testable import RgCommand
@testable import RipgrepKit

@Suite struct RgExecutableTests {

    /// Run the executable inside a fresh `Shell` bound to a temp
    /// working directory. Captures stdout/stderr.
    ///
    /// Binding a fresh `Shell` puts every run on the *embedded*
    /// routing path, so the no-path stdin-vs-cwd decision is
    /// deterministic: it reads the bound `InputSource` (canonical
    /// `.empty` when no `stdin:` input is given), never the harness
    /// process's fd 0. `stdinIsReadable` pins the explicit override.
    private func run(_ argv: [String],
                     in tree: [String: String] = [:],
                     stdin input: String = "",
                     stdinIsReadable: Bool? = nil)
    async throws -> (stdout: String, stderr: String, exit: Int32, root: URL) {
        let root = try makeTree(tree)
        let env = Environment(
            variables: ProcessInfo.processInfo.environment,
            workingDirectory: root.path)
        let shell = Shell(environment: env)
        shell.stdin = input.isEmpty ? .empty : .string(input)
        let stdoutSink = OutputSink()
        let stderrSink = OutputSink()
        shell.stdout = stdoutSink
        shell.stderr = stderrSink
        let exit = try await Shell.$current.withValue(shell) {
            try await RgExecutable.run(
                argv: argv,
                stdin: shell.stdin,
                stdout: stdoutSink,
                stderr: stderrSink,
                stdinIsReadable: stdinIsReadable)
        }
        stdoutSink.finish()
        stderrSink.finish()
        let outString = await stdoutSink.readAllString()
        let errString = await stderrSink.readAllString()
        return (outString, errString, exit, root)
    }

    private func makeTree(_ tree: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rg-cli-\(UUID().uuidString)",
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

    @Test func matchesPlainPattern() async throws {
        let r = try await run(["beta", "."], in: [
            "a.txt": "alpha\nbeta\ngamma\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("beta"))
        #expect(r.stdout.contains("a.txt"))
    }

    @Test func exit1OnNoMatch() async throws {
        let r = try await run(["nothere", "."], in: [
            "a.txt": "alpha\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 1)
    }

    @Test func ignoreCase() async throws {
        let r = try await run(["-i", "BETA", "."], in: [
            "a.txt": "beta line\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("beta line"))
    }

    @Test func fixedStringsEscape() async throws {
        let r = try await run(["-F", "a.c", "."], in: [
            "x.txt": "a.c\nabc\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        // 'abc' shouldn't appear in output — only the literal 'a.c'.
        #expect(r.stdout.contains("a.c"))
        #expect(!r.stdout.contains("abc"))
    }

    @Test func lineNumberShortForm() async throws {
        let r = try await run(["-n", "beta", "."], in: [
            "x.txt": "alpha\nbeta\ngamma\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains(":2:"))
    }

    @Test func globIncludesOnlyMatchingFiles() async throws {
        let r = try await run(["-g", "*.txt", "beta", "."], in: [
            "a.txt": "beta\n",
            "b.md":  "beta\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(!r.stdout.contains("b.md"))
    }

    @Test func gitignoreRespectedByDefault() async throws {
        // `.git/HEAD` marks the tree as a real repo so the default
        // `--require-git` (true) doesn't skip the `.gitignore`.
        let r = try await run(["beta", "."], in: [
            ".git/HEAD":  "ref: refs/heads/main\n",
            ".gitignore": "*.log\n",
            "a.log":      "beta\n",
            "a.txt":      "beta\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(!r.stdout.contains("a.log"))
    }

    @Test func noIgnoreOverridesGitignore() async throws {
        let r = try await run(["--no-ignore", "beta", "."], in: [
            ".git/HEAD":  "ref: refs/heads/main\n",
            ".gitignore": "*.log\n",
            "a.log":      "beta\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.log"))
    }

    @Test func hiddenFlag() async throws {
        let r = try await run(["--hidden", "secret", "."], in: [
            ".hidden": "secret\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains(".hidden"))
    }

    @Test func countMode() async throws {
        let r = try await run(["-c", "x", "."], in: [
            "a.txt": "x\nx\ny\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt:2"))
    }

    @Test func filesWithMatchesMode() async throws {
        let r = try await run(["-l", "x", "."], in: [
            "a.txt": "x\n",
            "b.txt": "y\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(!r.stdout.contains("b.txt"))
    }

    @Test func contextLines() async throws {
        let r = try await run(["-C1", "beta", "."], in: [
            "a.txt": "alpha\nbeta\ngamma\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("alpha"))
        #expect(r.stdout.contains("beta"))
        #expect(r.stdout.contains("gamma"))
    }

    @Test func jsonModeEmitsValidJSONLines() async throws {
        let r = try await run(["--json", "beta", "."], in: [
            "a.txt": "beta line\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(!lines.isEmpty)
        // Every line should decode as a JSON object.
        for line in lines {
            let data = Data(line.utf8)
            _ = try JSONSerialization.jsonObject(with: data)
        }
        // First event is "begin", last is "summary".
        let firstObj = try JSONSerialization.jsonObject(
            with: Data(lines[0].utf8)) as? [String: Any]
        #expect(firstObj?["type"] as? String == "begin")
        let lastObj = try JSONSerialization.jsonObject(
            with: Data(lines.last!.utf8)) as? [String: Any]
        #expect(lastObj?["type"] as? String == "summary")
    }

    @Test func stdinSearch() async throws {
        let r = try await run(["beta"], stdin: "alpha\nbeta\ngamma\n",
                              stdinIsReadable: true)
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("beta"))
    }

    // MARK: - No-path default (issue #65)

    /// `rg PATTERN` with no path must walk the cwd whenever stdin
    /// isn't readable input (a terminal, `/dev/null`, a closed fd —
    /// pinned here via the explicit override). Regression: the
    /// routing gated on `!isStdinTTY`, so any non-TTY-but-empty
    /// stdin shape made the no-path invocation read stdin and
    /// report no matches.
    @Test func noPathWalksCwdWhenStdinNotReadable() async throws {
        let r = try await run(["-l", "hello"], in: [
            "inner.txt":    "hello\n",
            "sub/deep.txt": "hello\n",
        ], stdinIsReadable: false)
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("inner.txt"))
        #expect(r.stdout.contains("sub/deep.txt"))
        // Real rg prints the cwd walk bare — no "./" prefix.
        #expect(!r.stdout.contains("./inner.txt"))
    }

    /// Embedded routing with no override: a bound (non-canonical)
    /// stdin is read — the host process's fd 0 has no say. This is
    /// the in-process entry point's contract: an embedder that
    /// attaches real input gets it consumed, whatever fd 0 looks
    /// like (review feedback on PR #71).
    @Test func noPathEmbeddedReadsBoundStdin() async throws {
        let r = try await run(["hello"], in: [
            "inner.txt": "hello from file\n",
        ], stdin: "hello from pipe\n")
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("hello from pipe"))
        #expect(!r.stdout.contains("hello from file"))
    }

    /// Embedded routing with no override and nothing attached — the
    /// shell bound the canonical `.empty` (what SwiftBash binds when
    /// no pipe or redirect feeds the command): walk the cwd.
    @Test func noPathEmbeddedNothingAttachedWalksCwd() async throws {
        let r = try await run(["-l", "hello"], in: [
            "inner.txt": "hello\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("inner.txt"))
    }

    /// The flip side: readable stdin (a pipe) wins over the cwd walk
    /// for a no-path invocation, and the cwd files stay untouched.
    @Test func noPathPrefersReadableStdinOverCwd() async throws {
        let r = try await run(["hello"], in: [
            "inner.txt": "hello from file\n",
        ], stdin: "hello from pipe\n", stdinIsReadable: true)
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.contains("hello from pipe"))
        #expect(!r.stdout.contains("hello from file"))
    }

    /// `rg --files` with no path lists the cwd bare (no "./" prefix),
    /// matching real rg.
    @Test func filesModeNoPathListsCwd() async throws {
        let r = try await run(["--files"], in: [
            "a.txt":     "x",
            "sub/b.txt": "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
        #expect(lines == ["a.txt", "sub/b.txt"])
    }

    @Test func filesMode() async throws {
        let r = try await run(["--files", "."], in: [
            "a.txt": "x",
            "sub/b.txt": "y",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("a.txt"))
        #expect(r.stdout.contains("sub/b.txt"))
    }

    @Test func typeListPrintsKnownType() async throws {
        let r = try await run(["--type-list"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.stdout.contains("swift: *.swift"))
    }

    @Test func quietExitOnlyNoOutput() async throws {
        let r = try await run(["-q", "beta", "."], in: [
            "a.txt": "beta\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 0)
        #expect(r.stdout.isEmpty)
    }

    @Test func parsesRgViaArgumentParser() throws {
        let cmd = try Rg.parse(["-i", "pat", "."])
        #expect(cmd.rawArgv == ["-i", "pat", "."])
    }

    // MARK: - Regression tests for review feedback

    /// `rg --files some/dir` (one positional, no pattern) must scope
    /// the listing to `some/dir`, not silently fall back to cwd.
    /// Regression: PR #35 review comment — the positional was being
    /// consumed as a pattern in `--files` mode.
    @Test func filesModeScopesToPositionalPath() async throws {
        let r = try await run(["--files", "sub"], in: [
            "a.txt":     "x",
            "sub/b.txt": "y",
            "sub/c.txt": "z",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted()
        // Every listed file should live under `sub/`.
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(line.hasPrefix("sub/"),
                    "unexpected listing outside sub/: \(line)")
        }
        #expect(lines.contains("sub/b.txt"))
        #expect(lines.contains("sub/c.txt"))
    }

    /// Missing input paths must exit with code 2 (error), not 1
    /// (no matches). Scripts gating on the exit code depend on the
    /// distinction. Regression: PR #35 review comment.
    @Test func missingPathExitsWithErrorCode() async throws {
        let r = try await run(["pattern", "does-not-exist-xyz"])
        defer { try? FileManager.default.removeItem(at: r.root) }
        #expect(r.exit == 2)
        #expect(r.stderr.contains("does-not-exist-xyz"))
        #expect(r.stderr.contains("No such file"))
    }

    /// JSON `summary.searches_with_match` must count only files that
    /// actually matched, not "any of the run matched". Regression: PR
    /// #35 review comment.
    @Test func jsonSummarySearchesWithMatchCountsMatchingFilesOnly() async throws {
        let r = try await run(["--json", "beta", "."], in: [
            "match.txt":   "beta\n",
            "nomatch.txt": "alpha\n",
            "match2.txt":  "beta line\nbeta-2\n",
        ])
        defer { try? FileManager.default.removeItem(at: r.root) }
        let lines = r.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let summary = try JSONSerialization.jsonObject(
            with: Data(lines.last!.utf8)) as? [String: Any]
        let data = summary?["data"] as? [String: Any]
        let stats = data?["stats"] as? [String: Any]
        let searches = stats?["searches"] as? Int
        let withMatch = stats?["searches_with_match"] as? Int
        #expect(searches == 3)
        #expect(withMatch == 2)
    }
}

#endif  // !os(Android)
