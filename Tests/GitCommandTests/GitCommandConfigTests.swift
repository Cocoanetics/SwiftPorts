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
    private func makeRoot() throws -> (root: URL, home: URL, work: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (root.resolvingSymlinksInPath(), home.resolvingSymlinksInPath(), work.resolvingSymlinksInPath())
    }

    /// `git <args>` in `work` under a sandbox whose home is `home`: stdout,
    /// stderr (an error's lines included) and the exit status.
    private func git(
        _ args: [String], root: URL, home: URL, work: URL
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(
            stdout: out, stderr: err,
            environment: Environment(
                variables: ["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1"], workingDirectory: work.path))
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
        return (await out.readAllString(), printed, failure?.exitCode ?? 0)
    }

    @Test("--global works anywhere, and starts ~/.gitconfig")
    func globalOutsideARepository() async throws {
        let (root, home, work) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ args: [String]) async throws -> (stdout: String, stderr: String, status: Int32) {
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
        let (root, home, work) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try "[user]\n\tname = Global Name\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let init_ = Process()
        init_.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        init_.arguments = ["git", "init", "-q"]
        init_.currentDirectoryURL = work
        try init_.run()
        init_.waitUntilExit()

        let merged = try await git(["config", "user.name"], root: root, home: home, work: work)
        #expect(merged.stdout == "Global Name\n")
        // --local looks at the repository's own file only.
        let local = try await git(["config", "--local", "user.name"], root: root, home: home, work: work)
        #expect(local.status == 1)
    }

    @Test("a plain write or --local needs a repository")
    func writesNeedARepository() async throws {
        let (root, home, work) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let plain = try await git(["config", "pull.rebase", "true"], root: root, home: home, work: work)
        #expect(plain.stderr == "fatal: not in a git directory\n")
        #expect(plain.status == 128)

        let local = try await git(["config", "--local", "pull.rebase", "true"], root: root, home: home, work: work)
        #expect(local.stderr == "fatal: --local can only be used inside a git repository\n")
        #expect(local.status == 128)
    }
}
#endif
