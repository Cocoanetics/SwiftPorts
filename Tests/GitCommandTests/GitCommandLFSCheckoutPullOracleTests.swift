#if !os(Android)
import ArgumentParser
import Foundation
import Testing
@testable import GitCommand

@Suite("git lfs checkout / pull argv parsing")
struct GitCommandLFSCheckoutPullParsingTests {
    private func parse(_ args: [String]) throws -> any ParsableCommand {
        let root = try #require(GitCommand.parseAsRoot(args) as? LFSCommand)
        return try LFSCommand.parseSubcommand(root.arguments)
    }

    @Test func checkoutFlags() throws {
        let plain = try #require(parse(["lfs", "checkout"]) as? LFSCheckout)
        #expect(!plain.base && !plain.ours && !plain.theirs && plain.to == nil && plain.arguments.isEmpty)

        let globs = try #require(parse(["lfs", "checkout", "*.dat", "dir/**"]) as? LFSCheckout)
        #expect(globs.arguments == ["*.dat", "dir/**"])

        let conflict = try #require(parse(
            ["lfs", "checkout", "--ours", "--to", "out.dat", "file.dat"]) as? LFSCheckout)
        #expect(conflict.ours && !conflict.base && !conflict.theirs)
        #expect(conflict.to == "out.dat" && conflict.arguments == ["file.dat"])

        let multi = try #require(parse(
            ["lfs", "checkout", "--base", "--theirs", "--to=dest.dat", "a.dat"]) as? LFSCheckout)
        #expect(multi.base && multi.theirs && multi.to == "dest.dat" && multi.arguments == ["a.dat"])
    }

    @Test(arguments: [
        ["-I", "*.bin", "-X", "skip/**"],
        ["-I*.bin", "-Xskip/**"],
        ["--include=*.bin", "--exclude=skip/**"]
    ])
    func pullFlags(_ flags: [String]) throws {
        let command = try #require(parse(["lfs", "pull", "origin"] + flags) as? LFSPull)
        #expect(command.include == "*.bin" && command.exclude == "skip/**")
        #expect(command.arguments == ["origin"])

        let defaults = try #require(parse(["lfs", "pull"]) as? LFSPull)
        #expect(defaults.arguments.isEmpty && defaults.include == nil && defaults.exclude == nil)

        let emptyInclude = try #require(parse(["lfs", "pull", "--include="]) as? LFSPull)
        #expect(emptyInclude.include == "")

        let emptyShortInclude = try #require(parse(["lfs", "pull", "-I", ""]) as? LFSPull)
        #expect(emptyShortInclude.include == "")

        let literalEquals = try #require(parse(["lfs", "pull", "-I="]) as? LFSPull)
        #expect(literalEquals.include == "=")

        let emptyExclude = try #require(parse(["lfs", "pull", "--exclude="]) as? LFSPull)
        #expect(emptyExclude.exclude == "")
    }
}
#endif

#if os(macOS) || os(Linux)
import Foundation
import GitLFSKit
import GitLFSTestSupport
import ShellKit
import SwiftGit
import Testing
@testable import GitCommand

@Suite("git lfs checkout / pull oracle (git-lfs 3.7.1)", .serialized,
       .enabled(if: LFSSamePathOracle.isAvailable, "git-lfs 3.7.1 is not on PATH"))
struct GitCommandLFSCheckoutPullOracleTests {
    private struct TwinClones {
        let oracle: LFSSamePathOracle
        let server: LFSTestServer
        let bare: URL
        let reference: URL
        let port: URL
        let files: [(path: String, data: Data)]

        static func with(
            files: [(String, Data)],
            extraConfig: [(String, String)] = [],
            useReference: Bool = false,
            _ body: (TwinClones) async throws -> Void
        ) async throws {
            let oracle = try LFSSamePathOracle()
            let server = try await LFSTestServer.start()
            try GitLFSKit.installFilter()
            defer {
                try? GitLFSKit.uninstallFilter()
                oracle.cleanup()
            }
            do {
                let seed = try oracle.repository("seed")
                let bare = try oracle.repository("remote.git", bare: true)
                try oracle.git(["config", "lfs.url", server.endpoint.absoluteString], in: seed)
                try oracle.git(["remote", "add", "origin", bare.path], in: seed)
                try oracle.track(["*.dat", "*.bin"], in: seed)
                for (path, data) in files {
                    try oracle.write(path, data, in: seed)
                }
                try oracle.add([".gitattributes"] + files.map(\.0), in: seed)
                try oracle.commit("lfs fixtures", in: seed)
                try oracle.git(["push", "origin", "main"], in: seed)

                let reference = try skipSmudgeClone(
                    oracle: oracle, bare: bare, name: "clone-ref",
                    lfsURL: server.endpoint.absoluteString, extraConfig: extraConfig,
                    reference: useReference ? seed : nil)
                let port = try skipSmudgeClone(
                    oracle: oracle, bare: bare, name: "clone-port",
                    lfsURL: server.endpoint.absoluteString, extraConfig: extraConfig,
                    reference: useReference ? seed : nil)
                let twin = TwinClones(
                    oracle: oracle, server: server, bare: bare,
                    reference: reference, port: port, files: files)
                try await body(twin)
            } catch {
                await server.shutdown()
                throw error
            }
            await server.shutdown()
        }

        private static func skipSmudgeClone(
            oracle: LFSSamePathOracle, bare: URL, name: String,
            lfsURL: String, extraConfig: [(String, String)], reference: URL?
        ) throws -> URL {
            let dest = oracle.root.appendingPathComponent(name)
            let referenceArguments = reference.map { ["--reference", $0.path] } ?? []
            try oracle.git(
                ["-c", "filter.lfs.smudge=git-lfs smudge --skip -- %f",
                 "-c", "filter.lfs.process=git-lfs filter-process --skip",
                 "clone", "-q"] + referenceArguments + [bare.path, dest.path],
                in: oracle.root)
            try oracle.git(["lfs", "install", "--local"], in: dest)
            try oracle.git(["config", "lfs.url", lfsURL], in: dest)
            for (key, value) in extraConfig {
                try oracle.git(["config", key, value], in: dest)
            }
            return dest
        }

        func indexedOID(_ path: String, in repo: URL) throws -> String {
            let line = try oracle.git(["ls-files", "-s", "--", path], in: repo).stdout
            let parts = line.split(whereSeparator: \.isWhitespace)
            return parts.count >= 2 ? String(parts[1]) : ""
        }

        func assertClean(_ repo: URL) async throws {
            let sysStatus = try oracle.git(["status", "--porcelain"], in: repo).stdout
            #expect(sysStatus.isEmpty, "system git status not clean: \(sysStatus)")
            let diffQuiet = try oracle.run(["diff-index", "--quiet", "HEAD", "--"], in: repo)
            #expect(diffQuiet.status == 0, "system git diff-index --quiet HEAD failed: \(diffQuiet.stderr)")
            let portStatus = try await oracle.port(["status", "--porcelain"], in: repo)
            #expect(portStatus.status == 0 && portStatus.stdout.isEmpty,
                    "SwiftGit status not clean: \(portStatus.stdout) \(portStatus.stderr)")
        }

        func assertWorktreesMatch() throws {
            for (path, _) in files {
                let refURL = reference.appendingPathComponent(path)
                let portURL = port.appendingPathComponent(path)
                #expect(FileManager.default.fileExists(atPath: refURL.path)
                    == FileManager.default.fileExists(atPath: portURL.path), "existence mismatch for \(path)")
                if FileManager.default.fileExists(atPath: refURL.path) {
                    #expect(try Data(contentsOf: portURL) == Data(contentsOf: refURL),
                            "content mismatch for \(path)")
                }
            }
        }
    }

    /// Regression test: GIT_LFS_SKIP_SMUDGE=1 clone restored by `git lfs pull`
    /// against LFSTestServer, matching git-lfs 3.7.1 output, exit status, media
    /// bytes, unchanged pointer OID in the index, and clean git status.
    @Test func pullRestoresSkippedSmudgeClone() async throws {
        let files: [(String, Data)] = [
            ("root.dat", Data("root media bytes\n".utf8)),
            ("nested/deep/asset.bin", Data(repeating: 0x5A, count: 4096))
        ]
        try await TwinClones.with(files: files) { twin in
            let refOIDBefore = try twin.indexedOID("root.dat", in: twin.reference)
            let portOIDBefore = try twin.indexedOID("root.dat", in: twin.port)
            #expect(portOIDBefore == refOIDBefore)
            // Verify the clone actually started as a pointer stub (skip-smudge).
            let stub = try String(contentsOf: twin.port.appendingPathComponent("root.dat"), encoding: .utf8)
            #expect(stub.hasPrefix("version https://git-lfs.github.com/spec/v1\n"))

            let expected = try twin.oracle.run(["lfs", "pull"], in: twin.reference)
            let actual = try await twin.oracle.port(["lfs", "pull"], in: twin.port)

            #expect(actual.status == expected.status && actual.status == 0)
            #expect(LFSSamePathOracle.normalize(actual.stdout) == LFSSamePathOracle.normalize(expected.stdout))
            #expect(LFSSamePathOracle.normalize(actual.stderr) == LFSSamePathOracle.normalize(expected.stderr))

            for (path, data) in files {
                #expect(try Data(contentsOf: twin.port.appendingPathComponent(path)) == data)
            }
            try twin.assertWorktreesMatch()
            #expect(try twin.indexedOID("root.dat", in: twin.port) == portOIDBefore)
            #expect(try twin.indexedOID("nested/deep/asset.bin", in: twin.port)
                == twin.indexedOID("nested/deep/asset.bin", in: twin.reference))
            try await twin.assertClean(twin.reference)
            try await twin.assertClean(twin.port)
        }
    }

    @Test func pullReferenceCloneMakesZeroServerRequests() async throws {
        let data = Data("reference repository media\n".utf8)
        try await TwinClones.with(files: [("sub/asset.dat", data)], useReference: true) { twin in
            let oid = try Pointer.decode(Data(contentsOf: twin.port.appendingPathComponent("sub/asset.dat"))).oid
            let objectPath = ".git/lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)"
            for repo in [twin.reference, twin.port] {
                // The smudge filter imports reference objects even with --skip.
                // Remove only the clone's local link so pull must import it again.
                let localObject = repo.appendingPathComponent(objectPath)
                if FileManager.default.fileExists(atPath: localObject.path) {
                    try FileManager.default.removeItem(at: localObject)
                }
                #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(objectPath).path))
            }
            let before = twin.server.requests().count
            let expected = try twin.oracle.run(["lfs", "pull"], in: twin.reference.appendingPathComponent("sub"))
            let actual = try await twin.oracle.port(["lfs", "pull"], in: twin.port.appendingPathComponent("sub"))
            #expect(actual.status == expected.status && actual.status == 0)
            #expect(actual.stdout == expected.stdout && actual.stderr == expected.stderr)
            #expect(twin.server.requests().count == before)
            for repo in [twin.reference, twin.port] {
                #expect(try Data(contentsOf: repo.appendingPathComponent(objectPath)) == data)
                #expect(try Data(contentsOf: repo.appendingPathComponent("sub/asset.dat")) == data)
                try await twin.assertClean(repo)
            }
            try twin.assertWorktreesMatch()
        }
    }

    @Test func checkoutLocalObjectMakesZeroServerRequests() async throws {
        let files: [(String, Data)] = [
            ("a.dat", Data("local alpha\n".utf8)),
            ("sub/b.dat", Data("local beta\n".utf8))
        ]
        try await TwinClones.with(files: files) { twin in
            try twin.oracle.git(["lfs", "fetch"], in: twin.reference)
            try twin.oracle.git(["lfs", "fetch"], in: twin.port)
            let requestCountBeforeCheckout = twin.server.requests().count

            let expected = try twin.oracle.run(["lfs", "checkout"], in: twin.reference)
            let actual = try await twin.oracle.port(["lfs", "checkout"], in: twin.port)

            #expect(twin.server.requests().count == requestCountBeforeCheckout)
            #expect(actual.status == expected.status && actual.status == 0)
            #expect(normalizeRate(actual.stdout) == normalizeRate(expected.stdout))
            #expect(actual.stderr == expected.stderr)
            try twin.assertWorktreesMatch()
            for (path, data) in files {
                #expect(try Data(contentsOf: twin.port.appendingPathComponent(path)) == data)
            }
            try await twin.assertClean(twin.reference)
            try await twin.assertClean(twin.port)
        }
    }

    @Test func checkoutConflictStagesAndModifiedFilePreservation() async throws {
        let oracle = try LFSSamePathOracle()
        try GitLFSKit.installFilter()
        defer {
            try? GitLFSKit.uninstallFilter()
            oracle.cleanup()
        }

        func makeConflictRepo(_ name: String) throws -> URL {
            let repo = try oracle.repository(name)
            try oracle.track(["*.dat"], in: repo)
            try oracle.write("file.dat", "base-data\n", in: repo)
            try oracle.write("keep.dat", "keep-original\n", in: repo)
            try oracle.write("plain.txt", "base-plain\n", in: repo)
            try oracle.add([".gitattributes", "file.dat", "keep.dat", "plain.txt"], in: repo)
            try oracle.commit("base", in: repo)

            try oracle.git(["checkout", "-q", "-b", "other"], in: repo)
            try oracle.write("file.dat", "theirs-data\n", in: repo)
            try oracle.write("plain.txt", "theirs-plain\n", in: repo)
            try oracle.add(["file.dat", "plain.txt"], in: repo)
            try oracle.commit("theirs", in: repo)

            try oracle.git(["checkout", "-q", "main"], in: repo)
            try oracle.write("file.dat", "ours-data\n", in: repo)
            try oracle.write("plain.txt", "ours-plain\n", in: repo)
            try oracle.add(["file.dat", "plain.txt"], in: repo)
            try oracle.commit("ours", in: repo)
            return repo
        }

        let refRepo = try makeConflictRepo("conf-ref")
        let portRepo = try makeConflictRepo("conf-port")

        // Before merge: usage errors and non-conflicted error.
        let errorForms: [[String]] = [
            ["checkout", "--to", "base.txt"],
            ["checkout", "--base"],
            ["checkout", "--to", "base.txt", "--ours", "--theirs"],
            ["checkout", "--to", "base.txt", "--base"],
            ["checkout", "--to", "base.txt", "--base", "file.dat", "keep.dat"],
            ["checkout", "--to", "base.txt", "--base", "file.dat"]
        ]
        for form in errorForms {
            let expected = try oracle.run(["lfs"] + form, in: refRepo)
            let actual = try await oracle.port(["lfs"] + form, in: portRepo)
            #expect(actual.status == expected.status && actual.status == 2, "\(form)")
            #expect(actual.stdout == expected.stdout, "stdout \(form)")
            #expect(actual.stderr == expected.stderr, "stderr \(form)")
        }

        // Create real merge conflict in both repos.
        #expect(try oracle.run(["merge", "other"], in: refRepo).status != 0)
        #expect(try oracle.run(["merge", "other"], in: portRepo).status != 0)

        // Modified working-tree file must be preserved by checkout.
        try oracle.write("keep.dat", "user-edited-worktree\n", in: refRepo)
        try oracle.write("keep.dat", "user-edited-worktree\n", in: portRepo)
        let modExpected = try oracle.run(["lfs", "checkout", "keep.dat"], in: refRepo)
        let modActual = try await oracle.port(["lfs", "checkout", "keep.dat"], in: portRepo)
        #expect(modActual.status == modExpected.status && modActual.status == 0)
        #expect(try String(contentsOf: portRepo.appendingPathComponent("keep.dat"), encoding: .utf8)
            == "user-edited-worktree\n")

        // Extract --base, --ours, --theirs from root and from a subdirectory.
        for (flag, file, expectedBytes) in [
            ("--base", "base.txt", "base-data\n"),
            ("--ours", "ours.txt", "ours-data\n"),
            ("--theirs", "theirs.txt", "theirs-data\n")
        ] {
            let e = try oracle.run(["lfs", "checkout", flag, "--to", file, "file.dat"], in: refRepo)
            let a = try await oracle.port(["lfs", "checkout", flag, "--to", file, "file.dat"], in: portRepo)
            #expect(a.status == e.status && a.status == 0)
            #expect(a.stdout == e.stdout && a.stderr == e.stderr)
            #expect(try String(contentsOf: portRepo.appendingPathComponent(file), encoding: .utf8) == expectedBytes)
        }

        // Subdirectory invocation with relative --to and relative conflicted path.
        let refSub = refRepo.appendingPathComponent("sub/dir")
        let portSub = portRepo.appendingPathComponent("sub/dir")
        try FileManager.default.createDirectory(at: refSub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: portSub, withIntermediateDirectories: true)
        let subExp = try oracle.run(["lfs", "checkout", "--ours", "--to", "sub-ours.txt", "../../file.dat"], in: refSub)
        let subAct = try await oracle.port(["lfs", "checkout", "--ours", "--to", "sub-ours.txt", "../../file.dat"],
                                           in: portSub)
        #expect(subAct.status == subExp.status && subAct.status == 0)
        #expect(try String(contentsOf: portSub.appendingPathComponent("sub-ours.txt"), encoding: .utf8)
            == "ours-data\n")

        // Non-pointer conflicted file gives git-lfs's decoder error.
        let npExp = try oracle.run(["lfs", "checkout", "--ours", "--to", "plain-out.txt", "plain.txt"], in: refRepo)
        let npAct = try await oracle.port(["lfs", "checkout", "--ours", "--to", "plain-out.txt", "plain.txt"],
                                          in: portRepo)
        #expect(npAct.status == npExp.status && npAct.status == 2)
        #expect(npAct.stderr == npExp.stderr)
    }

    @Test func pullIncludeExcludeRemoteAndClearWithEmpty() async throws {
        let files: [(String, Data)] = [
            ("keep.bin", Data("bin-data\n".utf8)),
            ("dir/skip.dat", Data("skip-data\n".utf8)),
            ("other.dat", Data("other-data\n".utf8))
        ]
        try await TwinClones.with(files: files, extraConfig: [("lfs.fetchinclude", "keep.bin")]) { twin in
            // 1. Default pull honors lfs.fetchinclude ("keep.bin" only).
            let e1 = try twin.oracle.run(["lfs", "pull", "origin"], in: twin.reference)
            let a1 = try await twin.oracle.port(["lfs", "pull", "origin"], in: twin.port)
            #expect(a1.status == e1.status && a1.status == 0)
            #expect(a1.stdout == e1.stdout && a1.stderr == e1.stderr)
            try twin.assertWorktreesMatch()
            #expect(try Data(contentsOf: twin.port.appendingPathComponent("keep.bin")) == Data("bin-data\n".utf8))
            #expect(try String(contentsOf: twin.port.appendingPathComponent("other.dat"), encoding: .utf8)
                .hasPrefix("version https://git-lfs.github.com/spec/v1\n"))

            // 2. --include= clears lfs.fetchinclude, while -X excludes dir/**.
            let e2 = try twin.oracle.run(["lfs", "pull", "--include=", "-X", "dir/**"], in: twin.reference)
            let a2 = try await twin.oracle.port(["lfs", "pull", "--include=", "-X", "dir/**"], in: twin.port)
            #expect(a2.status == e2.status && a2.status == 0)
            #expect(a2.stdout == e2.stdout && a2.stderr == e2.stderr)
            try twin.assertWorktreesMatch()
            #expect(try Data(contentsOf: twin.port.appendingPathComponent("other.dat")) == Data("other-data\n".utf8))
            #expect(try String(contentsOf: twin.port.appendingPathComponent("dir/skip.dat"), encoding: .utf8)
                .hasPrefix("version https://git-lfs.github.com/spec/v1\n"))

            // 3. Invalid remote matches error and status 2 (paths normalized across twin dirs).
            let e3 = try twin.oracle.run(["lfs", "pull", "no-such-remote"], in: twin.reference)
            let a3 = try await twin.oracle.port(["lfs", "pull", "no-such-remote"], in: twin.port)
            #expect(a3.status == e3.status && a3.status == 2)
            let normalizedActual = a3.stderr
                .replacingOccurrences(of: "/private/var/", with: "/var/")
                .replacingOccurrences(of: twin.port.path, with: "<repo>")
            let normalizedExpected = e3.stderr
                .replacingOccurrences(of: "/private/var/", with: "/var/")
                .replacingOccurrences(of: twin.reference.path, with: "<repo>")
            #expect(normalizedActual == normalizedExpected)
        }
    }

    @Test func pullMissingRemoteObject() async throws {
        let present = Data("present-bytes\n".utf8)
        let missing = Data("missing-bytes\n".utf8)
        let files: [(String, Data)] = [("present.dat", present), ("missing.dat", missing)]
        try await TwinClones.with(files: files) { twin in
            let ptr = try twin.oracle.git(["cat-file", "-p", "HEAD:missing.dat"], in: twin.port).stdout
            let missingOID = try #require(ptr.split(separator: "\n")
                .first { $0.hasPrefix("oid sha256:") }?.dropFirst("oid sha256:".count))
            twin.server.inject(.objectStatus(oid: String(missingOID), code: 404))
            let expected = try twin.oracle.run(["lfs", "pull"], in: twin.reference)
            twin.server.inject(.objectStatus(oid: String(missingOID), code: 404))
            let actual = try await twin.oracle.port(["lfs", "pull"], in: twin.port)

            #expect(actual.status == expected.status && actual.status == 2)
            #expect(actual.stdout == expected.stdout)
            #expect(actual.stderr == expected.stderr)
            #expect(try Data(contentsOf: twin.port.appendingPathComponent("present.dat")) == present)
            try twin.assertWorktreesMatch()
        }
    }

    @Test func checkoutPartialFetchAndSubdirectoryInvocation() async throws {
        let files: [(String, Data)] = [
            ("top.dat", Data("top-bytes\n".utf8)),
            ("sub/inner.dat", Data("inner-bytes\n".utf8)),
            ("other/deep.dat", Data("deep-bytes\n".utf8))
        ]
        try await TwinClones.with(files: files) { twin in
            // Fetch only sub/inner.dat and top.dat; leave other/deep.dat un-fetched.
            try twin.oracle.git(["lfs", "fetch", "-X", "other/**"], in: twin.reference)
            try twin.oracle.git(["lfs", "fetch", "-X", "other/**"], in: twin.port)

            // Subdirectory checkout of inner.dat only.
            let e1 = try twin.oracle.run(
                ["lfs", "checkout", "inner.dat"], in: twin.reference.appendingPathComponent("sub"))
            let a1 = try await twin.oracle.port(
                ["lfs", "checkout", "inner.dat"], in: twin.port.appendingPathComponent("sub"))
            #expect(a1.status == e1.status && a1.status == 0)
            #expect(normalizeRate(a1.stdout) == normalizeRate(e1.stdout))
            #expect(a1.stderr == e1.stderr)
            let innerURL = twin.port.appendingPathComponent("sub/inner.dat")
            #expect(try Data(contentsOf: innerURL) == Data("inner-bytes\n".utf8))
            #expect(try String(contentsOf: twin.port.appendingPathComponent("top.dat"), encoding: .utf8)
                .hasPrefix("version https://git-lfs.github.com/spec/v1\n"))

            // Checkout all from root: top.dat restored, other/deep.dat reports skip on stderr.
            let e2 = try twin.oracle.run(["lfs", "checkout"], in: twin.reference)
            let a2 = try await twin.oracle.port(["lfs", "checkout"], in: twin.port)
            #expect(a2.status == e2.status && a2.status == 0)
            #expect(a2.stderr == e2.stderr)
            let expectedSkip = "Skipped checkout for \"other/deep.dat\", content not local. Use fetch to download.\n"
            #expect(a2.stderr == expectedSkip)
            #expect(try Data(contentsOf: twin.port.appendingPathComponent("top.dat")) == Data("top-bytes\n".utf8))
            try twin.assertWorktreesMatch()
        }
    }

    @Test func checkoutAndPullWithoutFilterInstalledAndBareRepo() async throws {
        let files: [(String, Data)] = [("a.dat", Data("not-installed\n".utf8))]
        try await TwinClones.with(files: files) { twin in
            try twin.oracle.git(["lfs", "uninstall", "--local"], in: twin.reference)
            try twin.oracle.git(["lfs", "uninstall", "--local"], in: twin.port)

            let ce = try twin.oracle.run(["lfs", "checkout"], in: twin.reference)
            let ca = try await twin.oracle.port(["lfs", "checkout"], in: twin.port)
            #expect(ca.status == ce.status && ca.status == 0)
            #expect(ca.stdout == ce.stdout)
            #expect(ca.stderr == ce.stderr)

            let pe = try twin.oracle.run(["lfs", "pull"], in: twin.reference)
            let pa = try await twin.oracle.port(["lfs", "pull"], in: twin.port)
            #expect(pa.status == pe.status && pa.status == 0)
            #expect(pa.stdout == pe.stdout)
            #expect(pa.stderr == pe.stderr)
            try twin.assertWorktreesMatch()

            // Bare repository checkout exits 0 with work-tree message on stdout.
            let be = try twin.oracle.run(["lfs", "checkout"], in: twin.bare)
            let ba = try await twin.oracle.port(["lfs", "checkout"], in: twin.bare)
            #expect(ba.status == be.status && ba.status == 0)
            #expect(ba.stdout == be.stdout && ba.stderr == be.stderr)
        }
    }

    @Test func forcedProgressOutput() async throws {
        let files: [(String, Data)] = [("a.dat", Data("progress-bytes\n".utf8))]
        try await TwinClones.with(files: files, extraConfig: [("lfs.forceprogress", "true")]) { twin in
            let pe = try twin.oracle.run(["lfs", "pull"], in: twin.reference)
            let pa = try await twin.oracle.port(["lfs", "pull"], in: twin.port)
            #expect(pa.status == pe.status && pa.status == 0)
            #expect(normalizeRate(pa.stdout) == normalizeRate(pe.stdout))
            #expect(pa.stderr == pe.stderr)
        }
    }

    private func normalizeRate(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\| [0-9.]+ [A-Z]?B/s"#, with: "| <rate>", options: .regularExpression)
    }
}
#endif
