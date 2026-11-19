#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("git lfs command oracle", .enabled(if: LFSCommandFixture.isAvailable, "git-lfs is not on PATH"))
struct GitCommandLFSOracleTests {
    @Test func rootAndVersion() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        let ours = try await fixture.run(["version"])
        #expect(ours.stdout.hasPrefix("git-lfs/3.7.1 (SwiftPorts; "))
        #expect(ours.stdout.contains("; swift "))
        #expect(ours.stderr.isEmpty && ours.status == 0)
        let root = try await fixture.run([])
        let expected = try fixture.system(["lfs"], in: fixture.theirs)
        #expect(root.stdout.components(separatedBy: "\n").dropFirst()
                == expected.stdout.components(separatedBy: "\n").dropFirst())
        #expect(root.status == expected.status && root.stderr == expected.stderr)
        try await fixture.compare(["no-such-command"])
    }

    @Test func pointer() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        try fixture.write("content", "hello\n")
        let generated = try await fixture.compare(["pointer", "--file=content"])
        try fixture.write("pointer", generated.stdout)
        for args in [
            ["--file=content", "--pointer=pointer"], ["--pointer=pointer"],
            ["--check", "--strict", "--file=pointer"], ["--check", "--no-strict", "--file=pointer"],
            ["--stdin"], ["--check", "--stdin", "--strict"],
            ["--file=content", "--stdin"], ["--pointer=pointer", "--stdin"],
            ["--check", "--strict", "--no-strict", "--file=pointer"],
            ["--check", "--pointer=pointer"], ["--check"], ["--file=missing"], []
        ] {
            try await fixture.compare(["pointer"] + args, input: Data(generated.stdout.utf8))
        }
        try fixture.write("pointer", generated.stdout.replacingOccurrences(of: "\n", with: "\r\n"))
        try await fixture.compare(["pointer", "--check", "--strict", "--file=pointer"])
        try await fixture.compare(["pointer", "--file=content", "--pointer=pointer"])
        try fixture.write("pointer", "not a pointer\n")
        try await fixture.compare(["pointer", "--pointer=pointer"])
        try await fixture.compare(["pointer", "--check", "--file=pointer"])
    }

    @Test(arguments: [[], ["--skip-smudge"], ["--skip-repo"], ["--manual"], ["--worktree"]])
    func installation(_ flags: [String]) async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        let scope = flags.contains("--worktree") ? [] : ["--local"]
        try await fixture.compare(["install"] + scope + flags)
        try fixture.compareFiles()
        try await fixture.compare(["install"] + scope + flags)
        try fixture.compareFiles()
        if !flags.contains("--manual") && !flags.contains("--skip-repo") {
            try await fixture.compare(["uninstall"] + scope + flags.filter { $0 != "--skip-smudge" })
            try fixture.compareFiles()
        }
    }

    @Test func hookConflictAndForce() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        try fixture.write(".git/hooks/pre-push", "#!/bin/sh\necho custom\n")
        try await fixture.compare(["install", "--local"])
        try fixture.compareFiles()
        try await fixture.compare(["install", "--local", "--force"])
        try fixture.compareFiles()
        for repo in [fixture.ours, fixture.theirs] {
            #expect(try fixture.system(["config", "core.hooksPath", "custom/hooks"], in: repo).status == 0)
        }
        try await fixture.compare(["install", "--local"])
        try fixture.compareFiles(["custom/hooks/pre-push", "custom/hooks/post-checkout",
                                  "custom/hooks/post-commit", "custom/hooks/post-merge"])
    }

    @Test func attributes() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        try fixture.write("nested/.gitattributes", "*.png filter=lfs diff=lfs merge=lfs -text\n")
        try fixture.write(".gitattributes", "# comment\r\n*.bin filter=lfs diff=lfs merge=lfs -text\r\n")
        for args in [["track"], ["track", "--json"], ["track", "--no-excluded"],
                     ["track", "*.bin"], ["track", "file with spaces"], ["track", "#file"],
                     ["track", "--filename", "literal[1]*?.dat"],
                     ["track", "--filename", "literal[1]*?.dat"],
                     ["track", "--lockable", "*.bin"], ["track", "--not-lockable", "*.bin"],
                     ["track", "--dry-run", "*.zip"], ["track", "--no-modify-attrs", "*.zip"],
                     ["track", "--json", "*.zip"], ["track"], ["track", "--json"],
                     ["untrack", "file with spaces"], ["untrack", "./*.bin"], ["untrack"]] {
            try await fixture.compare(args)
            try fixture.compareFiles([".gitattributes", "nested/.gitattributes"])
        }
        try await fixture.compare(["track", "*.png"], subdirectory: "nested")
        try await fixture.compare(["track", "--lockable", "*.png"], subdirectory: "nested")
        try fixture.compareFiles([".gitattributes", "nested/.gitattributes"])
    }

    @Test func touchingTrackedFiles() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        try fixture.write("data.bin", "payload")
        try fixture.write("nested/other.bin", "payload")
        let old = Date(timeIntervalSince1970: 1_000_000)
        for repo in [fixture.ours, fixture.theirs] {
            #expect(try fixture.system(["add", "."], in: repo).status == 0)
            for path in ["data.bin", "nested/other.bin"] {
                try FileManager.default.setAttributes([.modificationDate: old],
                                                      ofItemAtPath: repo.appendingPathComponent(path).path)
            }
        }
        try await fixture.compare(["track", "--dry-run", "--verbose", "*.bin"])
        try await fixture.compare(["track", "--verbose", "*.bin"])
        try fixture.compareFiles()
        for path in ["data.bin", "nested/other.bin"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fixture.ours.appendingPathComponent(path).path)
            #expect((attributes[.modificationDate] as? Date ?? old) > old)
        }
    }
}
#endif
