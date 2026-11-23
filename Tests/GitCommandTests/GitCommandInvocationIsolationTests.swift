// `git -C` / `git -c` hold for one invocation (issue #260): the registered
// `git` command leaves the shell it runs in, the process, and the next
// invocation as they were, after a success and after a failure.
#if os(macOS) || os(Linux)
import Foundation
import ShellKit
import Testing

@Suite("git -C / -c last one invocation")
struct GitCommandInvocationIsolationTests {

    private struct Ambient: Equatable {
        let workingDirectory: String
        let environment: Environment
        let processDirectory: String
        let processParameters: String?
    }

    private func ambient(_ shell: Shell) -> Ambient {
        Ambient(workingDirectory: shell.environment.workingDirectory, environment: shell.environment,
                processDirectory: FileManager.default.currentDirectoryPath,
                processParameters: ProcessInfo.processInfo.environment["GIT_CONFIG_PARAMETERS"])
    }

    private func parentShell(_ oracle: GitInvocationOracle, _ extra: [String: String] = [:]) -> Shell {
        let shell = Shell(stdout: OutputSink(), stderr: OutputSink(),
                          environment: Environment(variables: oracle.environment(extra),
                                                   workingDirectory: oracle.root.path))
        shell.sandbox = oracle.sandbox
        return shell
    }

    @Test("a second invocation after a success sees none of the first's -C / -c")
    func afterSuccess() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        let parent = parentShell(oracle, ["GIT_CONFIG_PARAMETERS": "'p.q'='parent'"])
        let before = ambient(parent)

        let first = try await oracle.embedded(
            ["-C", "repo", "-c", "a.b=first", "config", "--list"], in: parent)
        #expect(first.status == 0)
        #expect(first.stdout.contains("p.q=parent\na.b=first\n"))
        #expect(ambient(parent) == before)

        // The same command, the same parent: no `a.b`, and the root is no repository.
        let second = try await oracle.embedded(["-C", "repo", "config", "--get", "a.b"], in: parent)
        #expect(second == .init(stdout: "", stderr: "", status: 1))
        let third = try await oracle.embedded(["config", "--get", "p.q"], in: parent)
        #expect(third.stdout == "parent\n")
        let fourth = try await oracle.embedded(["status"], in: parent)
        #expect(fourth.status != 0)
        #expect(ambient(parent) == before)
    }

    @Test("a second invocation after a failure sees none of the first's -C / -c")
    func afterFailure() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        let parent = parentShell(oracle)
        let before = ambient(parent)

        for failing in [["-c", "a.b=1", "-C", "repo", "-C", "missing", "status"],
                        ["-C", "repo", "-c", "invalid", "config", "--list"],
                        ["-C", "repo", "-c"]] {
            let failed = try await oracle.embedded(failing, in: parent)
            #expect(failed.status >= 128, "\(failing)")
            #expect(ambient(parent) == before, "\(failing)")

            let next = try await oracle.embedded(["-C", "repo", "-c", "c.d=2", "config", "--list"], in: parent)
            #expect(next.status == 0, "after \(failing)")
            #expect(!next.stdout.contains("a.b"), "after \(failing)")
            #expect(next.stdout.hasSuffix("c.d=2\n"), "after \(failing)")
            #expect(ambient(parent) == before, "after \(failing)")
        }
    }

    @Test("concurrent invocations each keep their own -C / -c")
    func concurrentInvocations() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let names = ["one", "two", "three", "four"]
        for name in names { try await oracle.repository(name) }
        let parent = parentShell(oracle)
        let results = try await withThrowingTaskGroup(of: (String, GitInvocationOracle.Output).self) { group in
            for name in names {
                group.addTask {
                    let output = try await oracle.embedded(
                        ["-C", name, "-c", "x.name=\(name)", "config", "--get", "x.name"], in: parent)
                    return (name, output)
                }
            }
            return try await group.reduce(into: [String: GitInvocationOracle.Output]()) { $0[$1.0] = $1.1 }
        }
        for name in names {
            #expect(results[name] == .init(stdout: "\(name)\n", stderr: "", status: 0))
        }
    }

    @Test("a -C directory the sandbox refuses is its denial, not a chdir error")
    func sandboxDenial() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        let secret = oracle.root.appendingPathComponent("secret")
        try await oracle.repository("secret")
        // A link inside, to the refused directory, is refused as well.
        try FileManager.default.createSymbolicLink(
            at: oracle.root.appendingPathComponent("door"), withDestinationURL: secret)
        let parent = parentShell(oracle)
        // One spelling for both sides (`resolvingSymlinksInPath` folds
        // `/private/var` to `/var` on macOS).
        let secretPath = secret.resolvingSymlinksInPath().path
        parent.sandbox = oracle.sandbox { url in
            let path = URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path
            if path == secretPath || path.hasPrefix(secretPath + "/") {
                throw Sandbox.Denial(url: url, reason: "permission denied by sandbox")
            }
        }
        let before = ambient(parent)
        for arguments in [["-C", "secret", "status"], ["-C", "door", "status"], ["-C", "repo", "-C", "../secret", "log"]] {
            let denied = try await oracle.embedded(arguments, in: parent)
            #expect(denied == .init(stdout: "", stderr: "git: permission denied by sandbox\n", status: 1),
                    "\(arguments)")
            #expect(ambient(parent) == before)
        }
        let allowed = try await oracle.embedded(["-C", "repo", "log", "--format=%s"], in: parent)
        #expect(allowed == .init(stdout: "one\n", stderr: "", status: 0))
    }

    @Test("the standalone executable's -C / -c don't reach its next run")
    func standaloneRuns() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        let first = try await oracle.port(.standalone, ["-C", "repo", "-c", "a.b=1", "config", "--get", "a.b"],
                                          in: oracle.root)
        #expect(first == .init(stdout: "1\n", stderr: "", status: 0))
        let second = try await oracle.port(.standalone, ["config", "--get", "a.b"],
                                           in: oracle.root.appendingPathComponent("repo"))
        #expect(second == .init(stdout: "", stderr: "", status: 1))
    }
}
#endif
