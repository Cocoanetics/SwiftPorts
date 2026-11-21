#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("git lfs status same-path oracle",
       .enabled(if: LFSSamePathOracle.isAvailable, "git-lfs 3.7.1 is not on PATH"))
struct GitCommandLFSStatusOracleTests {
    @Test func formatsTrackingAndSubdirectory() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("status")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("old.dat", "alpha", in: repo)
        try oracle.write("plain.txt", "ordinary", in: repo)
        try oracle.add([".gitattributes", "old.dat", "plain.txt"], in: repo)
        try oracle.commit("base", in: repo)
        try oracle.git(["update-ref", "refs/remotes/upstream/topic", "HEAD"], in: repo)
        try oracle.git(["config", "branch.main.remote", "upstream"], in: repo)
        try oracle.git(["config", "branch.main.merge", "refs/heads/topic"], in: repo)
        try oracle.git(["config", "branch.main.pushRemote", "push-only"], in: repo)
        try oracle.write("pushed.dat", "committed media", in: repo)
        try oracle.add(["pushed.dat"], in: repo)
        try oracle.commit("ahead", in: repo)
        try oracle.git(["mv", "old.dat", "new.dat"], in: repo)
        try oracle.write("new.dat", "changed after staging", in: repo)
        try oracle.write("added.dat", "new media", in: repo)
        try oracle.write("plain.txt", "ordinary staged", in: repo)
        try oracle.add(["added.dat", "plain.txt"], in: repo)
        try oracle.write("plain.txt", "ordinary unstaged", in: repo)
        let subdir = repo.appendingPathComponent("nested/deep")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        for cwd in [repo, subdir] {
            for flags in [[], ["-p"], ["--porcelain"], ["-j"], ["--json"], ["-p", "-j"], ["ignored", "args"]] {
                try await oracle.compare(["status"] + flags, in: cwd)
            }
        }
        try oracle.git(["checkout", "--detach", "-q"], in: repo)
        try await oracle.compare(["status"], in: repo)
    }

    @Test func partialTrackingFailure() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("tracking-failure")
        try oracle.write("base.txt", "base", in: repo)
        try oracle.add(["base.txt"], in: repo)
        try oracle.commit("base", in: repo)
        try oracle.git(["update-ref", "refs/remotes/upstream/main", "HEAD"], in: repo)
        try oracle.git(["config", "branch.main.remote", "upstream"], in: repo)
        try oracle.git(["config", "branch.main.merge", "refs/heads/main"], in: repo)
        try oracle.track(["a.dat"], in: repo)
        try oracle.write("a.dat", "pushed media", in: repo)
        try oracle.write("z.dat", String(repeating: "z", count: 900), in: repo)
        try oracle.add([".gitattributes", "a.dat", "z.dat"], in: repo)
        try oracle.commit("ahead", in: repo)
        let corrupt = try oracle.git(["rev-parse", "HEAD:z.dat"], in: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let object = repo.appendingPathComponent(".git/objects/\(corrupt.prefix(2))/\(corrupt.dropFirst(2))")
        // A valid zlib header and stored block expose the Git object header;
        // the following reserved DEFLATE block type fails the payload read.
        var compressed = Data([0x78, 0x01, 0x00, 0x6D, 0x00, 0x92, 0xFF])
        compressed += Data(("blob 900\0" + String(repeating: "z", count: 100)).utf8)
        compressed += Data([0x07, 0, 0, 0, 0])
        try compressed.write(to: object, options: .atomic)
        let expected = try oracle.run(["lfs", "status"], in: repo)
        let actual = try await oracle.port(["lfs", "status"], in: repo)
        #expect(expected.stdout.contains("\ta.dat ("))
        #expect(actual.stdout == expected.stdout)
        #expect(actual.status == expected.status && actual.status == 2)
        // Git's subprocess and libgit2 have different native corruption diagnostics.
        for result in [expected, actual] {
            #expect(result.stderr.contains("Could not scan for Git LFS objects"))
        }
    }

    @Test func unbornAndRepositoryErrors() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("unborn")
        for flags in [[], ["-p"], ["-j"]] { try await oracle.compare(["status"] + flags, in: repo) }
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("added.dat", "media", in: repo)
        try oracle.add([".gitattributes", "added.dat"], in: repo)
        for flags in [[], ["-p"], ["-j"]] { try await oracle.compare(["status"] + flags, in: repo) }
        let bare = try oracle.repository("bare", bare: true)
        try await oracle.compare(["status"], in: bare)
        try await oracle.compare(["status"], in: oracle.home)
    }

    @Test(arguments: [false, true])
    func missingIndexedBlobKeepsFullAnnotation(modification: Bool) async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("missing")
        if modification {
            try oracle.write("x.dat", "ordinary file", in: repo)
            try oracle.add(["x.dat"], in: repo)
            try oracle.commit("base", in: repo)
            try FileManager.default.removeItem(at: repo.appendingPathComponent("x.dat"))
        }
        let missing = String(repeating: "d", count: 40)
        try oracle.git(["update-index", "--add", "--cacheinfo", "100644,\(missing),x.dat"], in: repo)
        let result = try await oracle.compare(["status"], in: repo)
        let annotation = modification ? " -> ?: <missing>)\n" : "\tx.dat (?: <missing>)\n"
        #expect(result.stdout.contains(annotation))
        #expect(result.status == 0 && result.stderr.isEmpty)
    }

    @Test func missingCleanIndexedBlobStillRenders() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("missing-clean")
        try oracle.write("x.dat", "ordinary file", in: repo)
        try oracle.add(["x.dat"], in: repo)
        let oid = try oracle.git(["rev-parse", ":x.dat"], in: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let object = repo.appendingPathComponent(".git/objects/\(oid.prefix(2))/\(oid.dropFirst(2))")
        try FileManager.default.removeItem(at: object)
        for flags in [[], ["-p"], ["-j"]] {
            let result = try await oracle.compare(["status"] + flags, in: repo)
            #expect(result.status == 0 && result.stderr.isEmpty)
            if flags.isEmpty { #expect(result.stdout.contains("\tx.dat (?: <missing>)\n")) }
        }
    }

    @Test(arguments: [true, false])
    func quotedPaths(quotePath: Bool) async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("quoted")
        if !quotePath { try oracle.git(["config", "core.quotePath", "false"], in: repo) }
        try oracle.track(["*.dat"], in: repo)
        let names = ["a\nb.dat", "a\tb.dat", "a\"b.dat", "a\\b.dat", "café.dat", "space name.dat",
                     "nested/a\nb.dat", "bell\u{07}.dat", "delete\u{7F}.dat"]
        for (offset, name) in names.enumerated() {
            try oracle.write(name, "media \(offset)", in: repo)
        }
        try oracle.add([".gitattributes"] + names, in: repo)
        let subdir = repo.appendingPathComponent("nested")
        for cwd in [repo, subdir] {
            for flags in [[], ["-p"], ["-j"]] { try await oracle.compare(["status"] + flags, in: cwd) }
        }
        try oracle.commit("names", in: repo)
        try oracle.git(["mv", names[0], "renamed\tfile.dat"], in: repo)
        try oracle.write(names[1], "dirty media", in: repo)
        try oracle.write(names[4], "staged media", in: repo)
        try oracle.add([names[4]], in: repo)
        for cwd in [repo, subdir] {
            for flags in [[], ["-p"], ["-j"]] { try await oracle.compare(["status"] + flags, in: cwd) }
        }
    }
}
#endif
