#if os(macOS) || os(Linux)
import Foundation
import Testing
import SwiftGit

@Suite("git lfs ls-files same-path oracle",
       .enabled(if: LFSSamePathOracle.isAvailable, "git-lfs 3.7.1 is not on PATH"))
struct GitCommandLFSLsFilesOracleTests {
    @Test func versionLinesAreTheOnlyNormalization() {
        let json = "{\n \"files\": null\n}\n"
        #expect(LFSSamePathOracle.normalize(json) == json)
        let versions = "git-lfs/3.7.1 (GitHub; darwin arm64)\n\(PortVersion.gitLine)\ngit version 2.54.0\n"
            + "git-lfs/not-a-version\n"
        #expect(LFSSamePathOracle.normalize(versions) == "<version>\n<version>\n<version>\ngit-lfs/not-a-version\n")
        #expect(LFSSamePathOracle.isReferenceRelease("git-lfs/3.7.1 (GitHub; darwin arm64)\n"))
        #expect(!LFSSamePathOracle.isReferenceRelease("git-lfs/3.6.1 (GitHub; darwin arm64)\n"))
        #expect(!LFSSamePathOracle.isReferenceRelease("git lfs version 3.7.1\n"))
    }

    @Test func flagsPrecedenceAndNames() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try tracked(oracle, "flags")
        try oracle.write("a.dat", "alpha", in: repo)
        try oracle.add([".gitattributes", "a.dat"], in: repo)
        try oracle.commit("add", in: repo)
        let forms = [
            [], ["-l"], ["--long"], ["-s"], ["--size"], ["-l", "-s"], ["--long", "--size"],
            ["-n"], ["--name-only"], ["-n", "-s"], ["-n", "-l"], ["-j"], ["--json"],
            ["-d"], ["--debug"], ["-d", "-j"], ["-j", "-l", "-s"], ["-a"], ["--all"], ["--deleted"]
        ]
        for form in forms {
            try await oracle.compare(["ls-files"] + form, in: repo)
        }
        try await oracle.compare(["ls-files", "--all", "HEAD"], in: repo)
        try await oracle.compare(["ls-files", "-a", "main"], in: repo)
        try await oracle.compare(["ls-files", "--deleted", "HEAD", "HEAD"], in: repo)
        try await oracle.compare(["ls-files", "--", "--all"], in: repo)
        try await oracle.compare(["ls-files", "missing-ref"], in: repo)
    }

    @Test func sharedBlobStagedReplacementAndDeletion() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try tracked(oracle, "staged")
        try oracle.write("a.dat", "alpha", in: repo)
        try oracle.write("b.dat", "alpha", in: repo)
        try oracle.add([".gitattributes", "a.dat", "b.dat"], in: repo)
        try oracle.commit("same blob", in: repo)
        try await oracle.compare(["ls-files"], in: repo)
        try oracle.write("a.dat", "beta-beta", in: repo)
        try oracle.add(["a.dat"], in: repo)
        try oracle.git(["rm", "-q", "b.dat"], in: repo)
        try await oracle.compare(["ls-files"], in: repo)
        try await oracle.compare(["ls-files", "--all"], in: repo)
        try await oracle.compare(["ls-files", "--deleted"], in: repo)
        try await oracle.compare(["ls-files", "-j"], in: repo)
    }

    @Test func stagedRename() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try tracked(oracle, "rename")
        try oracle.write("c.dat", "gamma", in: repo)
        try oracle.add([".gitattributes", "c.dat"], in: repo)
        try oracle.commit("add", in: repo)
        try oracle.git(["mv", "c.dat", "d.dat"], in: repo)
        try await oracle.compare(["ls-files"], in: repo)
        try await oracle.compare(["ls-files", "--long"], in: repo)
    }

    @Test func historyDeletionAndLiteralRange() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try tracked(oracle, "history")
        try oracle.write("a.dat", "alpha", in: repo)
        try oracle.add([".gitattributes", "a.dat"], in: repo)
        try oracle.commit("a", in: repo)
        try oracle.git(["tag", "A"], in: repo)
        try oracle.write("b.dat", "bravo", in: repo)
        try oracle.add(["b.dat"], in: repo)
        try oracle.commit("b", in: repo)
        try oracle.git(["tag", "B"], in: repo)
        try oracle.git(["rm", "-q", "b.dat"], in: repo)
        try oracle.commit("delete b", in: repo)
        try await oracle.compare(["ls-files"], in: repo)
        try await oracle.compare(["ls-files", "--deleted"], in: repo)
        try await oracle.compare(["ls-files", "--all"], in: repo)
        try await oracle.compare(["ls-files", "A", "B"], in: repo)
        try await oracle.compare(["ls-files", "B", "A"], in: repo)
        try await oracle.compare(["ls-files", "A..B"], in: repo)
    }

    @Test func mergeBlobReachableFromExcludedRef() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try tracked(oracle, "merge")
        try oracle.write("shared.dat", "shared", in: repo)
        try oracle.add([".gitattributes", "shared.dat"], in: repo)
        try oracle.commit("base", in: repo)
        try oracle.git(["branch", "side"], in: repo)
        try oracle.write("main.dat", "main-only", in: repo)
        try oracle.add(["main.dat"], in: repo)
        try oracle.commit("main only", in: repo)
        try oracle.git(["checkout", "-q", "side"], in: repo)
        try oracle.write("side.dat", "side-only", in: repo)
        try oracle.add(["side.dat"], in: repo)
        try oracle.commit("side only", in: repo)
        try oracle.git(["checkout", "-q", "main"], in: repo)
        try oracle.git(["merge", "--no-ff", "-q", "-m", "merge", "side"], in: repo)
        try await oracle.compare(["ls-files", "side", "HEAD"], in: repo)
        try await oracle.compare(["ls-files", "main", "HEAD"], in: repo)
        try await oracle.compare(["ls-files", "side..HEAD"], in: repo)
    }

    @Test func includeExcludeIgnoresFetchConfig() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try tracked(oracle, "filter")
        try oracle.write("a.dat", "alpha", in: repo)
        try oracle.write("b.dat", "bravo", in: repo)
        try oracle.write("dir/c.dat", "charlie", in: repo)
        try oracle.add([".gitattributes", "a.dat", "b.dat", "dir/c.dat"], in: repo)
        try oracle.commit("files", in: repo)
        try oracle.git(["config", "lfs.fetchinclude", "nope"], in: repo)
        try oracle.git(["config", "lfs.fetchexclude", "*"], in: repo)
        try await oracle.compare(["ls-files"], in: repo)
        try await oracle.compare(["ls-files", "-I", "*.dat", "-X", "b.dat"], in: repo)
        try await oracle.compare(["ls-files", "--include", "dir/", "--exclude", "c.dat"], in: repo)
        try await oracle.compare(["ls-files", "-j", "-I", "dir/", "-X", "c.dat"], in: repo)
    }

    @Test func unbornBareSubdirectoryAndEmptyJSON() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let unborn = try oracle.repository("unborn")
        try await oracle.compare(["ls-files"], in: unborn)
        try await oracle.compare(["ls-files", "--json"], in: unborn)
        try oracle.track(["*.dat"], in: unborn)
        try oracle.write("z.dat", "z", in: unborn)
        try oracle.add([".gitattributes", "z.dat"], in: unborn)
        try await oracle.compare(["ls-files"], in: unborn)
        try await oracle.compare(["ls-files", "-j"], in: unborn)

        let plain = try oracle.repository("plain")
        try oracle.write("readme.txt", "notes", in: plain)
        try oracle.add(["readme.txt"], in: plain)
        try oracle.commit("notes", in: plain)
        try await oracle.compare(["ls-files", "--json"], in: plain)

        let source = try tracked(oracle, "source")
        try oracle.write("nested/deep/s.dat", "sub", in: source)
        try oracle.write("top.dat", "top", in: source)
        try oracle.add([".gitattributes", "nested/deep/s.dat", "top.dat"], in: source)
        try oracle.commit("tree", in: source)
        try await oracle.compare(["ls-files"], in: source.appendingPathComponent("nested/deep"))
        try await oracle.compare(["ls-files", "-d"], in: source.appendingPathComponent("nested"))
        try await oracle.compare(["ls-files", "-j"], in: source.appendingPathComponent("nested/deep"))
        let bare = try oracle.bareClone(of: source, named: "bare.git")
        try await oracle.compare(["ls-files"], in: bare)
        try await oracle.compare(["ls-files", "--json"], in: bare)
    }

    @Test func boundaryMalformedAndZeroSizePointers() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try tracked(oracle, "boundary")
        try oracle.write("payload.dat", "hello", in: repo)
        let pointer = try oracle.git(["lfs", "pointer", "--file=payload.dat"], in: repo).stdout
        try FileManager.default.removeItem(at: repo.appendingPathComponent("payload.dat"))
        for size in [1023, 1024, 1025] {
            try oracle.addRaw(padded(pointer, to: size), path: "pad-\(size).dat", in: repo)
        }
        try oracle.addRaw(Data("version https://git-lfs.github.com/spec/v1\noid nope\nsize 1\n".utf8),
                          path: "bad.dat", in: repo)
        try oracle.addRaw(Data(zeroPointer.utf8), path: "zero.dat", in: repo)
        try oracle.add([".gitattributes"], in: repo)
        try oracle.commit("raw blobs", in: repo)
        try await oracle.compare(["ls-files"], in: repo)
        try await oracle.compare(["ls-files", "--json"], in: repo)
        try await oracle.compare(["ls-files", "--long", "--size"], in: repo)
    }

    @Test func worktreeSizeVersusLocalStore() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try tracked(oracle, "states")
        let files = ["keep.dat": "hello", "nodl.dat": "world!", "nosize.dat": "abcdef", "neither.dat": "zzzz"]
        for (name, text) in files {
            try oracle.write(name, text, in: repo)
        }
        try oracle.add([".gitattributes"] + files.keys.sorted(), in: repo)
        try oracle.commit("states", in: repo)
        try removeObject("nodl.dat", in: repo, oracle: oracle)
        try oracle.write("nosize.dat", "ab", in: repo)
        try removeObject("neither.dat", in: repo, oracle: oracle)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("neither.dat"))
        try await oracle.compare(["ls-files"], in: repo)
        try await oracle.compare(["ls-files", "--json"], in: repo)
        try await oracle.compare(["ls-files", "--debug"], in: repo)
    }

    private func tracked(_ oracle: LFSSamePathOracle, _ name: String) throws -> URL {
        let repo = try oracle.repository(name)
        try oracle.track(["*.dat"], in: repo)
        return repo
    }

    private func padded(_ text: String, to size: Int) -> Data {
        var data = Data(text.utf8)
        if data.count < size { data.append(Data(repeating: 0x20, count: size - data.count)) }
        return data
    }

    private func removeObject(_ name: String, in repo: URL, oracle: LFSSamePathOracle) throws {
        let text = try oracle.git(["lfs", "pointer", "--file=\(name)"], in: repo).stdout
        let oid = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("oid ") else { return nil }
            return line.split(separator: ":").last.map(String.init)
        }.first ?? ""
        let object = repo.appendingPathComponent(
            ".git/lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)")
        try FileManager.default.removeItem(at: object)
    }
}

private let zeroPointer = """
version https://git-lfs.github.com/spec/v1
oid sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
size 0

"""
#endif
