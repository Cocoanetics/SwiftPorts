#if os(macOS) || os(Linux)
import Foundation
import Testing

extension GitCommandLFSStatusOracleTests {
    @Test func lfsAndGitTransitions() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("transitions")
        // Commit ordinary Git blobs first.
        try oracle.write("git-to-lfs.dat", "contents", in: repo)
        try oracle.write("convert-same.dat", "same contents", in: repo)
        try oracle.add(["git-to-lfs.dat", "convert-same.dat"], in: repo)
        try oracle.commit("ordinary blobs", in: repo)

        // Track *.dat and *.bin, add an LFS *.bin file, and commit tracking rules.
        try oracle.track(["*.dat", "*.bin"], in: repo)
        try oracle.write("lfs-to-git.bin", "original lfs", in: repo)
        try oracle.add([".gitattributes", "lfs-to-git.bin"], in: repo)
        try oracle.commit("track dat and bin", in: repo)

        // Git -> LFS change (new content) and Git -> LFS conversion (same content).
        try oracle.write("git-to-lfs.dat", "contents +extra", in: repo)
        try oracle.add(["git-to-lfs.dat"], in: repo)
        try oracle.git(["add", "--renormalize", "convert-same.dat"], in: repo)
        // JSON must exclude Git->LFS entries because blobInfoFrom classifies the source side.
        let jsonGitToLFS = try await oracle.compare(["status", "--json"], in: repo)
        #expect(jsonGitToLFS.stdout == "{\"files\":{}}\n")
        try await compareForms(oracle, [[], ["-p"]], in: repo)

        // LFS -> Git transition: untrack *.bin (leaving *.dat tracked) and restage lfs-to-git.bin.
        try oracle.git(["lfs", "untrack", "*.bin"], in: repo)
        try oracle.write("lfs-to-git.bin", "now ordinary git", in: repo)
        try oracle.add([".gitattributes", "lfs-to-git.bin"], in: repo)
        // JSON includes LFS->Git because the source side is LFS.
        let jsonLFSToGit = try await oracle.compare(["status", "--json"], in: repo)
        #expect(jsonLFSToGit.stdout.contains("\"lfs-to-git.bin\":{\"status\":\"M\"}"))
        try await compareForms(oracle, Self.allForms, in: repo)
    }

    @Test func deletionsAndFileToDirectory() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("deletions")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("base.txt", "base", in: repo)
        try oracle.add([".gitattributes", "base.txt"], in: repo)
        try oracle.commit("init", in: repo)
        try oracle.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
        try oracle.git(["config", "branch.main.remote", "origin"], in: repo)
        try oracle.git(["config", "branch.main.merge", "refs/heads/main"], in: repo)

        try oracle.write("staged-del.dat", "staged delete", in: repo)
        try oracle.write("unstaged-del.dat", "unstaged delete", in: repo)
        try oracle.write("mod-then-del.dat", "before mod", in: repo)
        try oracle.write("plain-file", "file", in: repo)
        try oracle.write("lfs-file.dat", "lfs to dir", in: repo)
        try oracle.add(
            ["staged-del.dat", "unstaged-del.dat", "mod-then-del.dat", "plain-file", "lfs-file.dat"],
            in: repo)
        try oracle.commit("files", in: repo)

        // Staged deletion of an unpushed LFS file, unstaged deletion, staged add then disk delete,
        // and staged mod then disk delete.
        try oracle.git(["rm", "-q", "staged-del.dat"], in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("unstaged-del.dat"))
        try oracle.write("add-then-del.dat", "ephemeral", in: repo)
        try oracle.add(["add-then-del.dat"], in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("add-then-del.dat"))
        try oracle.write("mod-then-del.dat", "staged mod", in: repo)
        try oracle.add(["mod-then-del.dat"], in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("mod-then-del.dat"))

        // Unstaged file-to-directory replacement (both ordinary Git file and LFS file).
        try FileManager.default.removeItem(at: repo.appendingPathComponent("plain-file"))
        try oracle.write("plain-file/a.dat", "nested under plain", in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("lfs-file.dat"))
        try oracle.write("lfs-file.dat/b.dat", "nested under lfs", in: repo)
        try await compareForms(oracle, Self.allForms, in: repo)

        // Staged file-to-directory replacement (matches upstream t-status.sh "status (file to dir)").
        try oracle.add(["plain-file", "lfs-file.dat"], in: repo)
        try await compareForms(oracle, Self.allForms, in: repo)
    }

    @Test func renamesTypeChangesAndConflicts() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("renames-types")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("clean-old.dat", "clean rename payload", in: repo)
        try oracle.write("dirty-old.dat", "dirty rename payload", in: repo)
        try oracle.write("unpaired-old.dat", "unpaired payload", in: repo)
        try oracle.write("to-link.dat", "was regular lfs", in: repo)
        try oracle.write("target.txt", "symlink target", in: repo)
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("from-link.dat").path, withDestinationPath: "target.txt")
        try oracle.add(
            [".gitattributes", "clean-old.dat", "dirty-old.dat", "unpaired-old.dat",
             "to-link.dat", "target.txt", "from-link.dat"],
            in: repo)
        try oracle.commit("base", in: repo)

        // Clean staged rename, dirty staged rename (staged R overwrites unstaged A in JSON;
        // uncached precedes cached in porcelain), and unstaged deletion + staged addition of same content.
        try oracle.git(["mv", "clean-old.dat", "clean-new.dat"], in: repo)
        try oracle.git(["mv", "dirty-old.dat", "dirty-new.dat"], in: repo)
        try oracle.write("dirty-new.dat", "dirty after move", in: repo)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("unpaired-old.dat"))
        try oracle.write("unpaired-new.dat", "unpaired payload", in: repo)
        try oracle.add(["unpaired-new.dat"], in: repo)

        // Type changes: regular LFS -> symlink (unstaged), symlink -> regular LFS (staged clean).
        try FileManager.default.removeItem(at: repo.appendingPathComponent("to-link.dat"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.appendingPathComponent("to-link.dat").path, withDestinationPath: "target.txt")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("from-link.dat"))
        try oracle.write("from-link.dat", "now regular lfs", in: repo)
        try oracle.add(["from-link.dat"], in: repo)
        try await compareForms(oracle, Self.allForms, in: repo)

        // Stage regular->symlink and dirty symlink->regular.
        try oracle.add(["to-link.dat"], in: repo)
        try oracle.write("from-link.dat", "dirty after type change", in: repo)
        try await compareForms(oracle, Self.allForms, in: repo)
    }

    @Test func mergeConflicts() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("conflicts")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("a.dat", "base-lfs", in: repo)
        try oracle.write("plain.txt", "base-plain\n", in: repo)
        try oracle.add([".gitattributes", "a.dat", "plain.txt"], in: repo)
        try oracle.commit("base", in: repo)

        try oracle.git(["checkout", "-q", "-b", "side"], in: repo)
        try oracle.write("a.dat", "theirs-lfs", in: repo)
        try oracle.write("plain.txt", "theirs-plain\n", in: repo)
        try oracle.add(["a.dat", "plain.txt"], in: repo)
        try oracle.commit("theirs", in: repo)

        try oracle.git(["checkout", "-q", "main"], in: repo)
        try oracle.write("a.dat", "ours-lfs", in: repo)
        try oracle.write("plain.txt", "ours-plain\n", in: repo)
        try oracle.add(["a.dat", "plain.txt"], in: repo)
        try oracle.commit("ours", in: repo)

        let merge = try oracle.run(["merge", "side"], in: repo)
        #expect(merge.status != 0)
        try await compareConflictForms(oracle, in: repo)

        // Even when the worktree matches stage 2's target bytes, upstream's update-index refresh still fails.
        try oracle.write("a.dat", "ours-lfs", in: repo)
        try await compareConflictForms(oracle, in: repo)
    }

    private func compareConflictForms(_ oracle: LFSSamePathOracle, in repo: URL) async throws {
        // Upstream invokes the host git binary for `git update-index -q --refresh`, so its stderr embeds
        // the host executable path; normalize only that executable token while comparing everything else raw.
        func normalizeGitBinary(_ stderr: String) -> String {
            stderr.replacingOccurrences(
                of: #"error running [^\n]+? 'update-index'"#,
                with: "error running git 'update-index'",
                options: .regularExpression)
        }
        for flags in Self.allForms {
            let expected = try oracle.run(["lfs", "status"] + flags, in: repo)
            let actual = try await oracle.port(["lfs", "status"] + flags, in: repo)
            let label = flags.joined(separator: " ")
            #expect(actual.stdout == expected.stdout, "stdout \(label)")
            #expect(actual.stderr == normalizeGitBinary(expected.stderr), "stderr \(label)")
            #expect(actual.status == expected.status && actual.status == 2, "status \(label)")
        }
    }

    @Test func missingSourceBlobAndMissingLocalLFSPayload() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("missing-source-and-payload")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("missing-src.dat", "source-a", in: repo)
        try oracle.write("no-payload.dat", "cached-payload", in: repo)
        try oracle.write("clean-no-payload.dat", "clean-cached", in: repo)
        try oracle.add([".gitattributes", "missing-src.dat", "no-payload.dat", "clean-no-payload.dat"], in: repo)
        try oracle.commit("base", in: repo)

        // Remove local LFS object payloads in .git/lfs/objects while keeping Git pointer blobs intact.
        for name in ["no-payload.dat", "clean-no-payload.dat"] {
            let pointer = try oracle.git(["show", "HEAD:\(name)"], in: repo).stdout
            let oid = try #require(pointer.split(separator: "\n").compactMap { line -> String? in
                guard line.hasPrefix("oid sha256:") else { return nil }
                return String(line.dropFirst("oid sha256:".count))
            }.first)
            let lfsObject = repo.appendingPathComponent(
                ".git/lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)")
            try FileManager.default.removeItem(at: lfsObject)
        }
        try oracle.write("no-payload.dat", "edited without local payload", in: repo)
        try await compareForms(oracle, Self.allForms, in: repo)

        // Remove the HEAD Git blob for missing-src.dat and stage a new pointer (t-status.sh).
        let headOID = try oracle.git(["rev-parse", "HEAD:missing-src.dat"], in: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.removeItem(
            at: repo.appendingPathComponent(".git/objects/\(headOID.prefix(2))/\(headOID.dropFirst(2))"))
        try oracle.write("missing-src.dat", "replacement-b", in: repo)
        try oracle.add(["missing-src.dat"], in: repo)
        let result = try await oracle.compare(["status"], in: repo)
        #expect(result.stdout.contains("\tmissing-src.dat (?: <missing> -> LFS: "))
        try await compareForms(oracle, [["-p"], ["-j"]], in: repo)
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
        for flags in Self.coreForms {
            let result = try await oracle.compare(["status"] + flags, in: repo)
            #expect(result.status == 0 && result.stderr.isEmpty)
            if flags.isEmpty { #expect(result.stdout.contains("\tx.dat (?: <missing>)\n")) }
        }
    }

    @Test(arguments: [true, false])
    func quotedPathsAndJsonEscaping(quotePath: Bool) async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("quoted")
        if !quotePath { try oracle.git(["config", "core.quotePath", "false"], in: repo) }
        try oracle.track(["*.dat"], in: repo)
        let names = ["Z.dat", "a\nb.dat", "a\tb.dat", "a\"b.dat", "a\\b.dat", "a<&>b.dat",
                     "sep\u{2028}\u{2029}.dat", "café.dat", "space name.dat",
                     "nested/a\nb.dat", "bell\u{07}.dat", "delete\u{7F}.dat"]
        for (offset, name) in names.enumerated() {
            try oracle.write(name, "media \(offset)", in: repo)
        }
        try oracle.add([".gitattributes"] + names, in: repo)
        let subdir = repo.appendingPathComponent("nested")
        for cwd in [repo, subdir] {
            try await compareForms(oracle, Self.coreForms, in: cwd)
        }
        try oracle.commit("names", in: repo)
        try oracle.git(["mv", names[1], "renamed\tfile.dat"], in: repo)
        try oracle.write(names[2], "dirty media", in: repo)
        try oracle.write(names[7], "staged media", in: repo)
        try oracle.add([names[7]], in: repo)
        for cwd in [repo, subdir] {
            try await compareForms(oracle, Self.coreForms, in: cwd)
        }
    }
}
#endif
