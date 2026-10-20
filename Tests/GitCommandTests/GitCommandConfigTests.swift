// `git config` outside a repository, as git works there: --global and
// --system need none, a plain read falls back to them, a plain write or
// --local needs a repository. The sandbox keeps every test away from the
// real ~/.gitconfig. The shared helpers are used by GitCommandConfigFileTests too.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
import SwiftGit
@testable import GitCommand

/// A sandbox root with a `home` (no `.gitconfig` yet) and a plain `work` directory.
struct ConfigFixture {
    let root: URL, home: URL, work: URL
}

/// What a `git` run printed, and its exit status.
struct ConfigOutput {
    let stdout: String, stderr: String, status: Int32
}

/// Runs `git` under a rooted sandbox with its own HOME, so no test touches
/// the real ~/.gitconfig.
protocol ConfigTestHelpers {}

extension ConfigTestHelpers {
    func makeRoot() throws -> ConfigFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return ConfigFixture(root: root.resolvingSymlinksInPath(), home: home.resolvingSymlinksInPath(),
                       work: work.resolvingSymlinksInPath())
    }

    /// `git <args>` in `work` under a sandbox whose home is `home`: stdout,
    /// stderr (an error's lines included) and the exit status.
    func git(
        _ args: [String], root: URL, home: URL, work: URL, environment: [String: String] = [:],
        sandboxed: Bool = true
    ) async throws -> ConfigOutput {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(
            stdout: out, stderr: err,
            environment: Environment(
                variables: ["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"].merging(environment) { $1 },
                workingDirectory: work.path))
        if sandboxed { shell.sandbox = Sandbox.rooted(at: root) }
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
        return ConfigOutput(stdout: await out.readAllString(), stderr: printed, status: failure?.exitCode ?? 0)
    }
}

@Suite("git config outside a repository")
struct GitCommandConfigTests: ConfigTestHelpers {

    @Test("--global works anywhere, and starts ~/.gitconfig")
    func globalOutsideARepository() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ args: [String]) async throws -> ConfigOutput {
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
        // git says nothing at all about a key that isn't there.
        let absent = try await run(["--global", "--get", "nope.key"])
        #expect(absent.status == 1 && absent.stderr.isEmpty && absent.stdout.isEmpty)

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
        func run(_ args: [String]) async throws -> ConfigOutput {
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

    @Test("--list prints the lowest level first, and a key without a value as its name")
    func listOrderAndValuelessEntries() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[g]\n\tx = 1\n[foo]\n\tbar\n[e]\n\tempty =\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let global = try await git(["config", "--global", "--list"], root: root, home: home, work: work)
        #expect(global.stdout == "g.x=1\nfoo.bar\ne.empty=\n")

        let initRepo = Process()
        initRepo.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        initRepo.arguments = ["git", "init", "-q"]
        initRepo.currentDirectoryURL = work
        try initRepo.run()
        initRepo.waitUntilExit()
        try "\n[l]\n\ty = 2\n".appendingToFile(work.appendingPathComponent(".git/config"))

        // In a repository: the global entries, then the repository's own.
        let all = try await git(["config", "--list"], root: root, home: home, work: work)
        let lines = all.stdout.split(separator: "\n").map(String.init)
        let globalAt = try #require(lines.firstIndex(of: "foo.bar"))
        let localAt = try #require(lines.firstIndex(of: "l.y=2"))
        #expect(globalAt < localAt)
        // --local: the repository's file only.
        let local = try await git(["config", "--local", "--list"], root: root, home: home, work: work)
        #expect(local.stdout.contains("l.y=2\n") && !local.stdout.contains("g.x=1"))
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
