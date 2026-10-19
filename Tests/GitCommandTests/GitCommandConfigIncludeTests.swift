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

    @Test("a scope's own entries only, as git has them; an unscoped read sees the included ones")
    func includesAreLeftOutOfAScope() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[x]\n\ty = included\n[a]\n\tb = from-include\n".write(
            to: home.appendingPathComponent("extra.cfg"), atomically: true, encoding: .utf8)
        try "[a]\n\tb = main\n[include]\n\tpath = extra.cfg\n[z]\n\tw = 1\n".write(
            to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        func run(_ args: [String]) async throws -> ConfigOutput {
            try await git(["config"] + args, root: root, home: home, work: work)
        }

        #expect(try await run(["--global", "--list"]).stdout == "a.b=main\ninclude.path=extra.cfg\nz.w=1\n")
        #expect(try await run(["--global", "--get", "x.y"]).status == 1)
        #expect(try await run(["--global", "--get", "a.b"]).stdout == "main\n")
        // Outside a repository an unscoped list reads the include in place.
        let all = try await run(["--list"]).stdout
        #expect(all.contains("x.y=included\n") && all.contains("a.b=from-include\n"))
    }

    @Test("a file an include pulls in must be inside the sandbox, nested ones too")
    func includesAreAuthorized() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-include-\(UUID().uuidString).cfg")
        try "[secret]\n\tkey = value\n".write(to: outside, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let nested = home.appendingPathComponent("nested.cfg")
        let global = home.appendingPathComponent(".gitconfig")
        for (name, target) in [("direct", global), ("nested", nested)] {
            try "[include]\n\tpath = \(outside.path)\n".write(to: target, atomically: true, encoding: .utf8)
            if name == "nested" {
                try "[include]\n\tpath = nested.cfg\n".write(to: global, atomically: true, encoding: .utf8)
            }
            // Scoped or unscoped, an include outside the root is refused.
            for args in [["--global", "--get", "a.b"], ["a.b"], ["--list"]] {
                await #expect(throws: Sandbox.Denial.self) {
                    try await self.git(["config"] + args, root: root, home: home, work: work)
                }
            }
        }
    }

    @Test("an include path is read as git reads a value: quotes and trailing comments")
    func includePathsAreParsedLikeValues() async throws {
        let fixture = try makeRoot()
        let (root, home, work) = (fixture.root, fixture.home, fixture.work)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitConfigOutside-quoted-\(UUID().uuidString).cfg")
        try "[secret]\n\tkey = value\n".write(to: outside, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let global = home.appendingPathComponent(".gitconfig")
        for line in ["path = \"\(outside.path)\" # a comment", "path = \(outside.path) ; a comment",
                     "path = \"\(outside.path)\""] {
            try "[include]\n\t\(line)\n".write(to: global, atomically: true, encoding: .utf8)
            await #expect(throws: Sandbox.Denial.self, "\(line)") {
                try await self.git(["config", "secret.key"], root: root, home: home, work: work)
            }
        }
    }
}
#endif
