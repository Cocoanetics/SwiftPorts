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
        for arguments in [["-C", "secret", "status"], ["-C", "door", "status"],
                          ["-C", "repo", "-C", "../secret", "log"]] {
            let denied = try await oracle.embedded(arguments, in: parent)
            #expect(denied == .init(stdout: "", stderr: "git: permission denied by sandbox\n", status: 1),
                    "\(arguments)")
            #expect(ambient(parent) == before)
        }
        // A -c include of a refused file is refused the same way.
        try "[a]\n\tb = secret\n".write(
            to: secret.appendingPathComponent("leak.cfg"), atomically: false, encoding: .utf8)
        let included = try await oracle.embedded(
            ["-c", "include.path=\(secretPath)/leak.cfg", "-C", "repo", "config", "--list"], in: parent)
        #expect(included == .init(stdout: "", stderr: "git: permission denied by sandbox\n", status: 1))
        let allowed = try await oracle.embedded(["-C", "repo", "log", "--format=%s"], in: parent)
        #expect(allowed == .init(stdout: "one\n", stderr: "", status: 0))
    }

    /// The paths a sandbox was asked about, physical.
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ url: URL) {
            let path = URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path
            lock.withLock { paths.append(path) }
        }
        func contains(_ path: String) -> Bool {
            let path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return lock.withLock { paths.contains(path) }
        }
        func reset() { lock.withLock { paths.removeAll() } }
    }

    @Test("an includeIf's file is asked of the sandbox only when git would read it")
    func conditionalIncludeSandbox() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        try await oracle.repository()
        let root = oracle.root.path
        for (name, text) in [("allowed.cfg", "[user]\n\tname = Allowed\n"), ("denied.cfg", "[user]\n\tname = Denied\n"),
                             ("unmatched.cfg", "[user]\n\tname = Unmatched\n")] {
            try text.write(to: oracle.root.appendingPathComponent(name), atomically: false, encoding: .utf8)
        }
        let requests = Requests()
        let parent = parentShell(oracle)
        let denied = URL(fileURLWithPath: "\(root)/denied.cfg").resolvingSymlinksInPath().path
        parent.sandbox = oracle.sandbox { url in
            requests.record(url)
            if URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path == denied {
                throw Sandbox.Denial(url: url, reason: "permission denied by sandbox")
            }
        }
        let before = ambient(parent)
        let getName = ["-C", "repo", "config", "--get", "user.name"]

        let allowed = try await oracle.embedded(["-c", "includeIf.onbranch:main.path=\(root)/allowed.cfg"] + getName,
                                                in: parent)
        #expect(allowed == .init(stdout: "Allowed\n", stderr: "", status: 0))
        #expect(requests.contains("\(root)/allowed.cfg"))

        let refused = try await oracle.embedded(
            ["-c", "includeIf.gitdir:\(root)/repo/.path=\(root)/denied.cfg"] + getName, in: parent)
        #expect(refused == .init(stdout: "", stderr: "git: permission denied by sandbox\n", status: 1))
        #expect(ambient(parent) == before)

        // A condition that doesn't hold never offers its file.
        requests.reset()
        for condition in ["onbranch:other", "gitdir:\(root)/elsewhere/"] {
            let unmatched = try await oracle.embedded(
                ["-c", "includeIf.\(condition).path=\(root)/unmatched.cfg"] + getName, in: parent)
            #expect(unmatched == .init(stdout: "Fixture\n", stderr: "", status: 0), "\(condition)")
        }
        #expect(!requests.contains("\(root)/unmatched.cfg"))

        // hasconfig reads its target even when nothing matches: it is asked,
        // and a refusal stops the command.
        let nowhere = "includeIf.hasconfig:remote.*.url:https://nowhere.example/**.path"
        let scanned = try await oracle.embedded(["-c", "\(nowhere)=\(root)/unmatched.cfg"] + getName, in: parent)
        #expect(scanned == .init(stdout: "Fixture\n", stderr: "", status: 0))
        #expect(requests.contains("\(root)/unmatched.cfg"))
        let scanDenied = try await oracle.embedded(["-c", "\(nowhere)=\(root)/denied.cfg"] + getName, in: parent)
        #expect(scanDenied == .init(stdout: "", stderr: "git: permission denied by sandbox\n", status: 1))

        // Nothing of the refused runs is left for the next one.
        let next = try await oracle.embedded(getName, in: parent)
        #expect(next == .init(stdout: "Fixture\n", stderr: "", status: 0))
        #expect(ambient(parent) == before)
    }

    @Test("under a path mapping, -C walks a symlink before a later '..', as chdir does")
    func mappedPhysicalTraversal() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        // The workspace is the shell's `/`: repositories `/A` and `/B`, and
        // `/A/link` leading to `/B/nested`, so `link/..` is `/B` on disk
        // (and `/A` read as text).
        let workspace = oracle.root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        for name in ["A", "B"] {
            let repo = try await oracle.repository("workspace/\(name)")
            try await oracle.gitOK(["commit", "-q", "--allow-empty", "-m", "in \(name)"], in: repo)
        }
        let nested = workspace.appendingPathComponent("B/nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("A/link"), withDestinationURL: nested)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("A/outside"), withDestinationURL: oracle.root)
        let temporary = oracle.root.appendingPathComponent("tmp", isDirectory: true)
        let shell = Shell(stdout: OutputSink(), stderr: OutputSink(),
                          environment: Environment(variables: oracle.environment(), workingDirectory: "/A"))
        shell.sandbox = Sandbox(
            documentsDirectory: temporary, downloadsDirectory: temporary, libraryDirectory: temporary,
            moviesDirectory: temporary, musicDirectory: temporary, picturesDirectory: temporary,
            sharedPublicDirectory: temporary, temporaryDirectory: temporary, trashDirectory: temporary,
            userDirectory: temporary, cachesDirectory: temporary, homeDirectory: oracle.home,
            pathMapping: PathMapping(mounts: [.init(virtual: "/", host: workspace.path)]),
            authorize: { _ in })
        let subjects = ["log", "-1", "--format=%s"]
        for arguments in [["-C", "link/.."], ["-C", "link", "-C", ".."], ["-C", "/A/link/../."]] {
            let output = try await oracle.embedded(arguments + subjects, in: shell)
            #expect(output == .init(stdout: "in B\n", stderr: "", status: 0), "\(arguments)")
        }
        let plain = try await oracle.embedded(["-C", "../A"] + subjects, in: shell)
        #expect(plain == .init(stdout: "in A\n", stderr: "", status: 0))
        // What git's chdir refuses on the way, and a link out of every mount.
        for (operand, reason) in [("file.txt/..", "Not a directory"), ("missing/..", "No such file or directory"),
                                  ("outside", "No such file or directory")] {
            let refused = try await oracle.embedded(["-C", operand, "status"], in: shell)
            #expect(refused == .init(stdout: "", stderr: "fatal: cannot change to '\(operand)': \(reason)\n",
                                     status: 128), "\(operand)")
        }
        #expect(shell.environment.workingDirectory == "/A")
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
