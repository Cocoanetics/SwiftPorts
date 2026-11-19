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

    /// `folder2/*` in git-lfs `TestGetTrackedFiles` includes `folder2/folder3/deep.txt`
    /// because the pattern matches the parent directory. `assets/*.bin` does not:
    /// `sub` is not `*.bin`, so the descendant stays untouched.
    @Test func trackParentDirectoryMatchesTouchIndexedDescendants() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        let tracked = [
            "assets/model.bin", "assets/readme.txt", "assets/sub/model.bin", "assets/sub/deep/model.bin"
        ]
        let untouched = ["other/model.bin"]
        for path in tracked + untouched {
            try fixture.write(path, "payload")
        }
        let old = Date(timeIntervalSince1970: 1_000_000)
        for repo in [fixture.ours, fixture.theirs] {
            #expect(try fixture.system(["add", "."], in: repo).status == 0)
        }
        func stamp() throws {
            for repo in [fixture.ours, fixture.theirs] {
                for path in tracked + untouched {
                    try FileManager.default.setAttributes(
                        [.modificationDate: old], ofItemAtPath: repo.appendingPathComponent(path).path)
                }
            }
        }
        func modified(_ path: String, in repo: URL) throws -> Date {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: repo.appendingPathComponent(path).path)
            return attributes[.modificationDate] as? Date ?? .distantPast
        }
        func expectDates(_ advanced: [String], held: [String]) throws {
            for repo in [fixture.ours, fixture.theirs] {
                for path in advanced {
                    #expect(try modified(path, in: repo) > old, "advanced \(path)")
                }
                for path in held {
                    #expect(try modified(path, in: repo) <= old, "held \(path)")
                }
            }
        }

        try stamp()
        let negative = try await fixture.compare(["track", "--dry-run", "--verbose", "assets/*.bin"])
        #expect(negative.stdout.contains("Found 1 files previously added to Git matching pattern: assets/*.bin"))
        #expect(negative.stdout.contains("Touching \"assets/model.bin\""))
        #expect(!negative.stdout.contains("assets/sub"))
        try expectDates([], held: tracked + untouched)
        try fixture.compareFiles()

        let dryRun = try await fixture.compare(["track", "--dry-run", "--verbose", "assets/*"])
        #expect(dryRun.stdout.contains("Found 4 files previously added to Git matching pattern: assets/*"))
        #expect(dryRun.stdout.contains("Touching \"assets/sub/model.bin\""))
        #expect(dryRun.stdout.contains("Touching \"assets/sub/deep/model.bin\""))
        #expect(!dryRun.stdout.contains("other/model.bin"))
        try expectDates([], held: tracked + untouched)

        try await fixture.compare(["track", "--verbose", "assets/*"])
        try fixture.compareFiles()
        try expectDates(tracked, held: untouched)

        // From inside assets/, the same root pattern is reported relative to
        // the working directory and still touches the indexed descendants.
        try stamp()
        let nestedDry = try await fixture.compare(
            ["track", "--dry-run", "--verbose", "assets/*"], subdirectory: "assets")
        #expect(nestedDry.stdout.contains("Found 4 files previously added to Git matching pattern: assets/*"))
        #expect(nestedDry.stdout.contains("Touching \"sub/model.bin\""))
        #expect(nestedDry.stdout.contains("Touching \"sub/deep/model.bin\""))
        #expect(!nestedDry.stdout.contains("Touching \"assets/"))
        try expectDates([], held: tracked + untouched)
        try await fixture.compare(["track", "--verbose", "assets/*"], subdirectory: "assets")
        try fixture.compareFiles([".gitattributes", "assets/.gitattributes"])
        try expectDates(tracked, held: untouched)
    }

    /// `foo/**/` matches a directory inside `foo`, not `foo` itself. git-lfs
    /// touches `foo/bar/b` and leaves the direct child `foo/a` alone.
    /// `foo/**` still includes that direct child.
    @Test func trackDirectoryGlobRequiresChildDirectory() async throws {
        let fixture = try LFSCommandFixture()
        defer { fixture.cleanup() }
        for path in [
            "foo/a", "foo/bar/b", "foo/baz/qux/d", "other/e", "a/b/i", "a/b/c/h", "root.txt"
        ] {
            try fixture.write(path, "payload")
        }
        for repo in [fixture.ours, fixture.theirs] {
            #expect(try fixture.system(["add", "."], in: repo).status == 0)
        }
        let dryRun = try await fixture.compare(["track", "--dry-run", "--verbose", "foo/**/"])
        #expect(dryRun.stdout.contains("Touching \"foo/bar/b\""))
        #expect(dryRun.stdout.contains("Touching \"foo/baz/qux/d\""))
        #expect(!dryRun.stdout.contains("Touching \"foo/a\""))
        for pattern in ["foo/**", "foo/**/**/", "*/**/", "**/", "foo/bar/**/", "foo/**/bar/", "a/b/**/"] {
            try await fixture.compare(["track", "--dry-run", "--verbose", pattern])
        }
        try await fixture.compare(["track", "--dry-run", "--verbose", "foo/**/"], subdirectory: "foo")
    }
}
#endif
