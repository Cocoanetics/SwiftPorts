// `[include]` in a config file: an explicit --global / --system leaves what
// is included out (git's --includes default), and what a file includes is
// read, so a sandbox has to allow it.
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

    @Test("in a sandbox a config file with an include section is refused, whatever its path says")
    func includesAreRefusedInASandbox() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        let global = home.appendingPathComponent(".gitconfig")
        // Spellings a path scan could get wrong: the point is that none is parsed.
        let sections = ["[include]\n\tpath = extra.cfg\n", "[INCLUDE]\n\tpath = \"extra.cfg\" # note\n",
                        "[includeIf \"gitdir:/nope/\"]\n\tpath = ../../outside\n",
                        "[include]\n\tpath = /allowed\\\n/../../outside\n"]
        for section in sections {
            try ("[a]\n\tb = c\n" + section).write(to: global, atomically: true, encoding: .utf8)
            for args in [["--global", "--get", "a.b"], ["a.b"], ["--list"], ["--global", "x.y", "z"]] {
                await #expect(throws: Sandbox.Denial.self, "\(section) \(args)") {
                    try await self.git(["config"] + args, root: root, home: home, work: work)
                }
            }
        }
        // A file without one is read as usual.
        try "[a]\n\tb = c\n".write(to: global, atomically: true, encoding: .utf8)
        #expect(try await git(["config", "a.b"], root: root, home: home, work: work).stdout == "c\n")
    }

    @Test("the XDG file is checked for an unscoped read even when ~/.gitconfig is the one --global uses")
    func xdgFileIsChecked() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[a]\n\tb = home\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        let xdgDirectory = home.appendingPathComponent(".config/git")
        try FileManager.default.createDirectory(at: xdgDirectory, withIntermediateDirectories: true)
        try "[include]\n\tpath = ../elsewhere\n".write(
            to: xdgDirectory.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        await #expect(throws: Sandbox.Denial.self) {
            try await self.git(["config", "a.b"], root: root, home: home, work: work)
        }

        // An XDG directory outside the sandbox is refused too.
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
