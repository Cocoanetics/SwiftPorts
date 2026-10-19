// `git config` outside a repository, as git works there: --global and
// --system need none, a plain read falls back to them, a plain write or
// --local needs a repository. The sandbox keeps every test away from the
// real ~/.gitconfig.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
import SwiftGit
@testable import GitCommand

@Suite("git config outside a repository")
struct GitCommandConfigTests {

    /// A sandbox root with a `home` (no `.gitconfig` yet) and a plain `work` directory.
    struct Fixture {
        let root: URL, home: URL, work: URL
    }

    /// What a `git` run printed, and its exit status.
    struct Output {
        let stdout: String, stderr: String, status: Int32
    }

    private func makeRoot() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return Fixture(root: root.resolvingSymlinksInPath(), home: home.resolvingSymlinksInPath(),
                       work: work.resolvingSymlinksInPath())
    }

    /// `git <args>` in `work` under a sandbox whose home is `home`: stdout,
    /// stderr (an error's lines included) and the exit status.
    private func git(
        _ args: [String], root: URL, home: URL, work: URL, environment: [String: String] = [:]
    ) async throws -> Output {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(
            stdout: out, stderr: err,
            environment: Environment(
                variables: ["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"].merging(environment) { $1 },
                workingDirectory: work.path))
        shell.sandbox = Sandbox.rooted(at: root)
        var failure: CLIError?
        do {
            try await shell.withCurrent {
                var command = try #require(try GitCommand.parseAsRoot(args) as? AsyncParsableCommand)
                try await command.run()
            }
        } catch let error as CLIError {
            failure = error
        }
        out.finish()
        err.finish()
        let printed = await err.readAllString() + (failure?.lines.map { $0 + "\n" }.joined() ?? "")
        return Output(stdout: await out.readAllString(), stderr: printed, status: failure?.exitCode ?? 0)
    }

    @Test("--global works anywhere, and starts ~/.gitconfig")
    func globalOutsideARepository() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ args: [String]) async throws -> Output {
            try await git(["config"] + args, root: root, home: home, work: work)
        }

        let set = try await run(["--global", "pull.rebase", "false"])
        #expect(set.status == 0 && set.stderr.isEmpty)
        #expect(try String(contentsOf: home.appendingPathComponent(".gitconfig"), encoding: .utf8)
                == "[pull]\n\trebase = false\n")

        #expect(try await run(["--global", "--get", "pull.rebase"]).stdout == "false\n")
        // A plain read, and --list, see the global file.
        #expect(try await run(["pull.rebase"]).stdout == "false\n")
        #expect(try await run(["--list"]).stdout.contains("pull.rebase=false\n"))
        #expect(try await run(["--global", "--get", "nope.key"]).status == 1)

        // Unsetting what isn't there is status 5.
        #expect(try await run(["--global", "--unset", "pull.rebase"]).status == 0)
        #expect(try await run(["--global", "--unset", "pull.rebase"]).status == 5)
        #expect(try await run(["pull.rebase"]).status == 1)
    }

    @Test("a plain read inside a repository sees the global value too")
    func plainReadIsMerged() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[user]\n\tname = Global Name\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let initRepo = Process()
        initRepo.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        initRepo.arguments = ["git", "init", "-q"]
        initRepo.currentDirectoryURL = work
        try initRepo.run()
        initRepo.waitUntilExit()

        let merged = try await git(["config", "user.name"], root: root, home: home, work: work)
        #expect(merged.stdout == "Global Name\n")
        // --local looks at the repository's own file only.
        let local = try await git(["config", "--local", "user.name"], root: root, home: home, work: work)
        #expect(local.status == 1)
    }

    @Test("a missing global file is an empty config for a get or unset, and an error to list")
    func missingGlobalFile() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ args: [String]) async throws -> Output {
            try await git(["config"] + args, root: root, home: home, work: work)
        }

        #expect(try await run(["--global", "--get", "a.b"]).status == 1)
        #expect(try await run(["--global", "--unset", "a.b"]).status == 5)
        // Neither started the file.
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".gitconfig").path))

        let list = try await run(["--global", "--list"])
        #expect(list.stderr
                == "fatal: unable to read config file '\(home.path)/.gitconfig': No such file or directory\n")
        #expect(list.status == 128)
    }

    @Test("--global --list lists the global file only")
    func listHonoursTheScope() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[g]\n\tx = 1\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        create.arguments = ["git", "init", "-q"]
        create.currentDirectoryURL = work
        try create.run()
        create.waitUntilExit()
        try "\n[l]\n\ty = 2\n".appendingToFile(work.appendingPathComponent(".git/config"))

        let global = try await git(["config", "--global", "--list"], root: root, home: home, work: work)
        #expect(global.stdout == "g.x=1\n")
        let all = try await git(["config", "--list"], root: root, home: home, work: work)
        #expect(all.stdout.contains("g.x=1\n") && all.stdout.contains("l.y=2\n"))
    }

    @Test("a --system write that can't create the file fails as git's does")
    func systemWriteWithoutPermission() async throws {
        // Only where /etc/gitconfig can't be started: never create it.
        guard !FileManager.default.fileExists(atPath: "/etc/gitconfig"),
              !FileManager.default.isWritableFile(atPath: "/etc") else { return }
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await git(["config", "--system", "a.b", "c"], root: root, home: home, work: work)
        #expect(result.stderr == "error: could not lock config file /etc/gitconfig: Permission denied\n")
        #expect(result.status == 255)

        // An explicit --system ignores GIT_CONFIG_NOSYSTEM, which the
        // helper sets: listing the missing file is still git's error.
        let list = try await git(["config", "--system", "--list"], root: root, home: home, work: work)
        #expect(list.stderr == "fatal: unable to read config file '/etc/gitconfig': No such file or directory\n")
        #expect(list.status == 128)
        let get = try await git(["config", "--system", "--get", "a.b"], root: root, home: home, work: work)
        #expect(get.status == 1)
    }

    @Test("GIT_CONFIG_SYSTEM names the system file, which is read even under GIT_CONFIG_NOSYSTEM")
    func systemFileFromTheEnvironment() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appendingPathComponent("system.cfg")
        let environment = ["GIT_CONFIG_SYSTEM": system.path]
        func run(_ args: [String]) async throws -> Output {
            try await git(["config"] + args, root: root, home: home, work: work, environment: environment)
        }

        // Missing: git's error names the file, and a get finds nothing.
        let missing = try await run(["--system", "--list"])
        #expect(missing.stderr == "fatal: unable to read config file '\(system.path)': No such file or directory\n")
        #expect(missing.status == 128)
        #expect(try await run(["--system", "--get", "a.b"]).status == 1)

        // A write starts it, and every read of it works despite NOSYSTEM.
        #expect(try await run(["--system", "a.b", "c"]).status == 0)
        #expect(try String(contentsOf: system, encoding: .utf8) == "[a]\n\tb = c\n")
        #expect(try await run(["--system", "--list"]).stdout == "a.b=c\n")
        #expect(try await run(["--system", "--get", "a.b"]).stdout == "c\n")
        #expect(try await run(["--system", "--unset", "a.b"]).status == 0)
        #expect(try await run(["--system", "--get", "a.b"]).status == 1)
    }

    @Test("a plain write or --local needs a repository")
    func writesNeedARepository() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }

        let plain = try await git(["config", "pull.rebase", "true"], root: root, home: home, work: work)
        #expect(plain.stderr == "fatal: not in a git directory\n")
        #expect(plain.status == 128)

        let local = try await git(["config", "--local", "pull.rebase", "true"], root: root, home: home, work: work)
        #expect(local.stderr == "fatal: --local can only be used inside a git repository\n")
        #expect(local.status == 128)
    }
}
private extension String {
    /// Appends `self` to the file at `url`.
    func appendingToFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
#endif
