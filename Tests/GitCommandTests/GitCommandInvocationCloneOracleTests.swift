// `git -c` / `GIT_CONFIG_COUNT` reach the repository `git clone` creates
// before its first checkout (issue #260), beyond the plain -c / COUNT case
// of `GitCommandInvocationOracleTests.cloneConfiguration`: their order, a
// -c include among them, and an include the sandbox refuses mid-clone.
#if os(macOS) || os(Linux)
import Foundation
import ShellKit
import Testing

@Suite("git -c reaches clone's first checkout, as system git's does")
struct GitCommandInvocationCloneOracleTests {

    /// A repository with LF text and no attributes, for `core.autocrlf` to
    /// turn into CRLF on checkout.
    private func source(_ oracle: GitInvocationOracle) async throws -> URL {
        let source = try await oracle.repository("source")
        try Data("two\nlines\n".utf8).write(to: source.appendingPathComponent("more.txt"))
        try await oracle.gitOK(["add", "more.txt"], in: source)
        try await oracle.gitOK(["commit", "-q", "-m", "two"], in: source)
        return source
    }

    /// The clone's text, a CR shown as `\r`, its status and whether it kept
    /// `core.autocrlf` (git doesn't: `-c` is not `clone --config`).
    private func cloneState(_ oracle: GitInvocationOracle, _ name: String = "dest") -> () async throws -> String {
        { () async throws -> String in
            let clone = oracle.root.appendingPathComponent(name)
            var state = ""
            for file in ["file.txt", "more.txt"] {
                let data = (try? Data(contentsOf: clone.appendingPathComponent(file))) ?? Data("<missing>".utf8)
                state += file + ": " + String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "\r", with: "\\r") + "\n"
            }
            let status = try await oracle.system(["status", "--porcelain"], in: clone)
            let kept = try await oracle.system(["config", "--local", "--get", "core.autocrlf"], in: clone)
            return state + "status \(status.status): \(status.stdout)local core.autocrlf \(kept.status): \(kept.stdout)"
        }
    }

    @Test("a later -c wins over GIT_CONFIG_COUNT for clone's checkout")
    func countedThenCommandLine() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let source = try await source(oracle)
        let counted = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.autocrlf", "GIT_CONFIG_VALUE_0": "true"]
        try await oracle.compare(["-c", "core.autocrlf=false", "clone", "-q", source.path, "dest"],
                                 in: oracle.root, environment: counted, state: cloneState(oracle))
    }

    @Test("a -c include.path takes its place among the clone's -c entries")
    func includedAutocrlf() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let source = try await source(oracle)
        try "[include]\n\tpath = nested.cfg\n".write(
            to: oracle.root.appendingPathComponent("crlf.cfg"), atomically: false, encoding: .utf8)
        try "[core]\n\tautocrlf = true\n".write(
            to: oracle.root.appendingPathComponent("nested.cfg"), atomically: false, encoding: .utf8)
        let include = "include.path=\(oracle.root.path)/crlf.cfg"
        for arguments in [
            ["-c", include, "clone", "-q", source.path, "dest"],
            ["-c", "core.autocrlf=false", "-c", include, "clone", "-q", source.path, "dest"],
            ["-c", include, "-c", "core.autocrlf=false", "clone", "-q", source.path, "dest"]
        ] {
            try await oracle.compare(arguments, in: oracle.root, state: cloneState(oracle))
        }
    }

    /// The registered command in a shell whose sandbox asks `authorize`.
    private func sandboxed(
        _ oracle: GitInvocationOracle, _ authorize: @escaping @Sendable (URL) async throws -> Void
    ) -> Shell {
        let shell = Shell(stdout: OutputSink(), stderr: OutputSink(),
                          environment: Environment(variables: oracle.environment(),
                                                   workingDirectory: oracle.root.path))
        shell.sandbox = oracle.sandbox(authorize: authorize)
        return shell
    }

    @Test("an include the sandbox refuses during clone leaves no clone behind; allowed, the retry checks out CRLF")
    func refusedIncludeThenRetry() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let source = try await source(oracle)
        try "[include]\n\tpath = nested.cfg\n".write(
            to: oracle.root.appendingPathComponent("crlf.cfg"), atomically: false, encoding: .utf8)
        try "[core]\n\tautocrlf = true\n".write(
            to: oracle.root.appendingPathComponent("nested.cfg"), atomically: false, encoding: .utf8)
        let nested = oracle.root.appendingPathComponent("nested.cfg").path
        let arguments = ["-c", "include.path=\(oracle.root.path)/crlf.cfg", "clone", "-q", source.path]
        // An empty destination that was there before stays, empty.
        let existing = oracle.root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        struct Refused: Error, CustomStringConvertible {
            var description: String { "nested.cfg is not allowed" }
        }
        let refusing = sandboxed(oracle) { url in
            if url.path == nested { throw Refused() }
        }
        for destination in ["dest", "existing"] {
            let refused = try await oracle.embedded(arguments + [destination], in: refusing)
            #expect(refused.status != 0, "\(refused)")
            #expect(refused.stderr.contains("nested.cfg is not allowed"), "\(refused)")
        }
        #expect(!FileManager.default.fileExists(atPath: oracle.root.appendingPathComponent("dest").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path).isEmpty)

        // Allowed only once asked: the first attempt is refused by the
        // include gate and rolled back, the retry after the sandbox allows
        // the file checks out what system git does.
        let asked = AskedPaths()
        let allowing = sandboxed(oracle) { await asked.add($0.path) }
        _ = try await oracle.system(arguments + ["expected"], in: oracle.root)
        let expected = try await cloneState(oracle, "expected")()
        #expect(expected.contains("file.txt: one\\r\n"), "\(expected)")
        for destination in ["dest", "existing"] {
            let allowed = try await oracle.embedded(arguments + [destination], in: allowing)
            #expect(allowed == .init(stdout: "", stderr: "", status: 0), "\(allowed)")
            #expect(try await cloneState(oracle, destination)() == expected, "\(destination)")
        }
        #expect(await asked.paths.contains(nested))
    }

    private actor AskedPaths {
        var paths: Set<String> = []
        func add(_ path: String) { paths.insert(path) }
    }
}
#endif
