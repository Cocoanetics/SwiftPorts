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
