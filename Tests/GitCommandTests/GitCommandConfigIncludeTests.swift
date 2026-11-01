// `[include]` in a config file: an explicit --global / --system leaves what
// is included out (git's --includes default), and what a file includes is
// read, so a sandbox has to authorise each file libgit2 opens. Compared with
// the real git, on a HOME and GIT_CONFIG_GLOBAL of the test's own.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitCommand

@Suite("git config includes")
struct GitCommandConfigIncludeTests: ConfigTestHelpers {

    @Test("without a sandbox, an explicit scope shows the file's own entries only")
    func includesAreLeftOutOfAScope() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[x]\n\ty = included\n[a]\n\tb = from-include\n".write(
            to: home.appendingPathComponent("extra.cfg"), atomically: true, encoding: .utf8)
        let main = home.appendingPathComponent("main.cfg")
        try "[a]\n\tb = main\n[include]\n\tpath = extra.cfg\n[z]\n\tw = 1\n".write(
            to: main, atomically: true, encoding: .utf8)
        // Without a sandbox, as the plain CLI runs; GIT_CONFIG_GLOBAL names the file.
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config", "--global"] + args, root: root, home: home, work: work,
                          environment: ["GIT_CONFIG_GLOBAL": main.path], sandboxed: false)
        }

        #expect(try await run(["--list"]).stdout == "a.b=main\ninclude.path=extra.cfg\nz.w=1\n")
        #expect(try await run(["--get", "x.y"]).status == 1)
        #expect(try await run(["--get", "a.b"]).stdout == "main\n")
    }

    /// The real git's output and status for `args`, with HOME and
    /// `GIT_CONFIG_GLOBAL` of its own and no system file.
    private func realGit(_ args: [String], home: URL, global: URL, work: URL) throws -> ConfigOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = work
        process.environment = ["HOME": home.path, "GIT_CONFIG_GLOBAL": global.path,
                               "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ConfigOutput(
            stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self),
            status: process.terminationStatus)
    }

    @Test("in a sandbox an include inside the root is read, as git reads it")
    func includeInsideTheRootIsRead() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[x]\n\ty = included\n".write(
            to: home.appendingPathComponent("extra.cfg"), atomically: true, encoding: .utf8)
        let global = home.appendingPathComponent(".gitconfig")
        try "[a]\n\tb = c\n[include]\n\tpath = extra.cfg\n".write(to: global, atomically: true, encoding: .utf8)
        for args in [["x.y"], ["--list"], ["--get", "a.b"]] {
            let ours = try await git(["config"] + args, root: root, home: home, work: work)
            let theirs = try realGit(["config"] + args, home: home, global: global, work: work)
            #expect(ours.stdout == theirs.stdout && ours.status == theirs.status, "\(args)")
        }
    }

    @Test("in a sandbox an include outside the root is denied, nested ones too")
    func includeOutsideTheRootIsDenied() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-inc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.cfg")
        try "[x]\n\ty = secret\n".write(to: secret, atomically: true, encoding: .utf8)
        let global = home.appendingPathComponent(".gitconfig")
        let nested = home.appendingPathComponent("nested.cfg")
        let spellings = ["[include]\n\tpath = \(secret.path)\n", "[INCLUDE]\n\tpath = \"\(secret.path)\" # note\n",
                         "[include]\n\tpath = nested.cfg\n"]
        try "[include]\n\tpath = \(secret.path)\n".write(to: nested, atomically: true, encoding: .utf8)
        for section in spellings {
            try ("[a]\n\tb = c\n" + section).write(to: global, atomically: true, encoding: .utf8)
            for args in [["--global", "--get", "a.b"], ["a.b"], ["--list"], ["--global", "x.z", "1"]] {
                await #expect(throws: Sandbox.Denial.self, "\(section) \(args)") {
                    try await self.git(["config"] + args, root: root, home: home, work: work)
                }
            }
        }
        // Without the include section, the file is read as usual.
        try "[a]\n\tb = c\n".write(to: global, atomically: true, encoding: .utf8)
        #expect(try await git(["config", "a.b"], root: root, home: home, work: work).stdout == "c\n")
    }

    @Test("an includeIf whose condition is false is not opened, so it is not denied")
    func falseConditionIsNotDenied() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = home.appendingPathComponent(".gitconfig")
        try """
            [a]
            \tb = c
            [includeIf "gitdir:/nope/"]
            \tpath = /nonexistent-outside/file
            [includeIf "onbranch:nope"]
            \tpath = /nonexistent-outside/file

            """.write(to: global, atomically: true, encoding: .utf8)
        let ours = try await git(["config", "a.b"], root: root, home: home, work: work)
        let theirs = try realGit(["config", "a.b"], home: home, global: global, work: work)
        #expect(ours.stdout == "c\n" && ours.stdout == theirs.stdout && ours.status == theirs.status)
    }

    @Test("set and unset look at the file itself, not at what it includes (#136)")
    func setAndUnsetIgnoreIncludedRepeats() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = home.appendingPathComponent(".gitconfig")
        let reference = home.appendingPathComponent("reference.cfg")
        let extra = home.appendingPathComponent("extra.cfg")
        let text = "[a]\n\tb = main\n[include]\n\tpath = extra.cfg\n"
        try "[a]\n\tb = included\n".write(to: extra, atomically: true, encoding: .utf8)
        for args in [["a.b", "new"], ["--unset", "a.b"], ["a.c", "new"], ["--unset", "a.c"]] {
            try text.write(to: global, atomically: true, encoding: .utf8)
            try text.write(to: reference, atomically: true, encoding: .utf8)
            let ours = try await git(["config", "--global"] + args, root: root, home: home, work: work)
            let theirs = try realGit(["config", "--global"] + args, home: home, global: reference, work: work)
            #expect(ours.status == theirs.status, "\(args)")
            // The entries, not the text: git also drops a section a key leaves empty.
            let entries = ["config", "--global", "--list"]
            #expect(try realGit(entries, home: home, global: global, work: work).stdout
                    == realGit(entries, home: home, global: reference, work: work).stdout, "\(args)")
        }
    }

    @Test("inside a repository, includes of its own config are gated too")
    func repositoryConfigIncludesAreGated() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.cfg")
        try "[x]\n\ty = secret\n".write(to: secret, atomically: true, encoding: .utf8)
        try "[x]\n\ty = inside\n".write(
            to: work.appendingPathComponent("inside.cfg"), atomically: true, encoding: .utf8)
        let initRepo = Process()
        initRepo.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        initRepo.arguments = ["git", "init", "-q"]
        initRepo.currentDirectoryURL = work
        initRepo.environment = ["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        try initRepo.run()
        initRepo.waitUntilExit()
        let local = work.appendingPathComponent(".git/config")
        let base = try String(contentsOf: local, encoding: .utf8)

        try (base + "[include]\n\tpath = ../inside.cfg\n").write(to: local, atomically: true, encoding: .utf8)
        #expect(try await git(["config", "x.y"], root: root, home: home, work: work).stdout == "inside\n")

        try (base + "[include]\n\tpath = \(secret.path)\n").write(to: local, atomically: true, encoding: .utf8)
        await #expect(throws: Sandbox.Denial.self) {
            try await self.git(["config", "x.y"], root: root, home: home, work: work)
        }
        await #expect(throws: Sandbox.Denial.self) {
            try await self.git(["status"], root: root, home: home, work: work)
        }
    }

    @Test("an XDG directory outside the sandbox is refused for an unscoped read")
    func xdgDirectoryOutsideIsRefused() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[a]\n\tb = home\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-xdg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        await #expect(throws: Sandbox.Denial.self) {
            try await self.git(["config", "a.b"], root: root, home: home, work: work,
                               environment: ["XDG_CONFIG_HOME": outside.path])
        }
    }
}
#endif
