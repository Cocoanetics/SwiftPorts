#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("git lfs config oracle", .enabled(if: LFSCommandFixture.isAvailable, "git-lfs is not on PATH"))
struct GitCommandLFSConfigOracleTests {
    @Test(arguments: [[], ["--system"], ["--file=settings.cfg"]])
    func destinations(_ flags: [String]) async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        try await fixture.compare(["install"] + flags)
        try fixture.compareFiles()
        let args = flags.first?.hasPrefix("--file=") == true ? ["--file=settings.cfg"]
            : flags.isEmpty ? ["--global"] : ["--system"]
        let expected = try fixture.system(["config"] + args + ["--list"], in: fixture.theirs)
        let actual = try fixture.system(["config"] + args + ["--list"], in: fixture.ours)
        #expect(actual.stdout.split(separator: "\n").sorted() == expected.stdout.split(separator: "\n").sorted())
        try await fixture.compare(["uninstall"] + flags)
        try fixture.compareFiles()
        try await fixture.compare(["uninstall"] + flags)
    }

    @Test func worktreeConfig() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        for repo in [fixture.ours, fixture.theirs] {
            #expect(try fixture.system(["config", "extensions.worktreeConfig", "true"], in: repo).status == 0)
        }
        try await fixture.compare(["install", "--worktree"])
        let expected = try fixture.system(["config", "--worktree", "--list"], in: fixture.theirs)
        let actual = try fixture.system(["config", "--worktree", "--list"], in: fixture.ours)
        #expect(actual.stdout.split(separator: "\n").sorted() == expected.stdout.split(separator: "\n").sorted())
        try fixture.compareFiles()
        try await fixture.compare(["uninstall", "--worktree"])
        try fixture.compareFiles([".git/config.worktree"])
    }

    @Test func preexistingValues() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        for repo in [fixture.ours, fixture.theirs] {
            for (key, value) in [("clean", "git-lfs clean %f"), ("smudge", "git-lfs smudge %f"),
                                 ("process", "git-lfs filter")] {
                #expect(try fixture.system(["config", "filter.lfs." + key, value], in: repo).status == 0)
            }
        }
        try await fixture.compare(["install", "--local"])
        try await fixture.compare(["install", "--local", "--skip-smudge"])
        try await fixture.compare(["install", "--local"])
        try fixture.compareFiles()
        for repo in [fixture.ours, fixture.theirs] {
            #expect(try fixture.system(["config", "filter.lfs.clean", "foreign clean"], in: repo).status == 0)
        }
        try await fixture.compare(["install", "--local"])
        try await fixture.compare(["install", "--local", "--force"])
        try fixture.compareFiles()
        try await fixture.compare(["install", "--local", "--system"])
        try await fixture.compare(["install", "--local", "--manual", "--force"])
    }

    @Test func preservedForeignHook() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        try await fixture.compare(["install", "--local"])
        try fixture.write(".git/hooks/pre-push", "#!/bin/sh\necho foreign\n")
        try await fixture.compare(["uninstall", "--local"])
        try fixture.compareFiles()
    }

    @Test func help() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        try await fixture.compare(["help"])
        let help = try await fixture.run(["--help"])
        let usage = try fixture.system(["lfs", "help"], in: fixture.theirs)
        // System git intercepts `git lfs --help` to launch man. Our in-process
        // command uses git-lfs's embedded usage text, also printed by `help`.
        #expect(help.stdout == usage.stdout && help.stderr.isEmpty && help.status == 0)
    }

    @Test func inputLineEndingsAndMacros() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        for repo in [fixture.ours, fixture.theirs] {
            #expect(try fixture.system(["config", "core.autocrlf", "input"], in: repo).status == 0)
        }
        try fixture.write(".gitattributes", "[attr]large filter=lfs diff=lfs merge=lfs -text\n*.bin large\n"
            + "*.excluded -filter\nonly-lock lockable\n")
        try fixture.write("nested/.gitattributes", "*.dat large\n")
        try await fixture.compare(["track"])
        try await fixture.compare(["track", "--json"])
        try await fixture.compare(["track", "--no-excluded"])
        try await fixture.compare(["track", "*.bin"])
        try await fixture.compare(["track", "*.new"])
        try fixture.compareFiles([".gitattributes", "nested/.gitattributes"])
    }
}
#endif
