#if os(macOS) || os(Linux)
import Foundation
import GitLFSTestSupport
import Testing

@Suite("LFS meter speed normalizer")
struct LFSMeterNormalizerTests {
    @Test func speedFieldOnly() {
        let done = "Uploading LFS objects: 100% (1/1), 13 B | 1.5 MB/s, done.\n"
        #expect(LFSSamePathOracle.normalizeMeterSpeed(done)
            == "Uploading LFS objects: 100% (1/1), 13 B | <speed>, done.\n")
        let padded = "Downloading LFS objects:  40% (0/1), 1 KB | 200 B/s   \r\n"
        #expect(LFSSamePathOracle.normalizeMeterSpeed(padded)
            == "Downloading LFS objects:  40% (0/1), 1 KB | <speed>\r\n")
        let other = "fetch abc => a.dat\n"
        #expect(LFSSamePathOracle.normalizeMeterSpeed(other) == other)
        #expect(LFSSamePathOracle.normalize(done) == done)
    }
}

/// Same repository shape, one fresh `LFSTestServer` per side. The endpoint and a batch
/// `expires_at` are the only fixture substitutions; `/locks/verify` text is compared raw.
@Suite("git lfs fetch/push same-path oracle",
       .enabled(if: LFSSamePathOracle.isAvailable, "git-lfs 3.7.1 is not on PATH"))
struct GitCommandLFSTransferOracleTests {
    private let prompt = ["GIT_TERMINAL_PROMPT": "0"]

    @Test func oursPushThenSystemFetch() async throws {
        try await roundTrip(referencePush: false)
    }

    @Test func systemPushThenOursFetch() async throws {
        try await roundTrip(referencePush: true)
    }

    @Test func pushAll() async throws {
        try await compareTransfer(
            files: [("a.dat", "alpha-lfs\n"), ("b.dat", "bravo-lfs\n")], excludeFirst: true
        ) { _ in ["push", "--all", "origin"] }
    }

    @Test func pushObjectID() async throws {
        try await compareTransfer { staged in
            // The remote is the first positional. A value before it is the remote name.
            ["push", "origin", "--object-id", staged.files[0].oid]
        }
    }

    @Test func pushDryRun() async throws {
        try await compareTransfer { _ in ["push", "--dry-run", "origin", "main"] }
    }

    @Test func fetchDryRun() async throws {
        try await compareTransfer(seed: true) { _ in ["fetch", "--dry-run"] }
    }

    @Test func fetchJSON() async throws {
        try await compareTransfer(seed: true) { _ in ["fetch", "--json"] }
    }

    @Test func invalidRemote() async throws {
        try await compareTransfer { _ in ["fetch", "not-a-remote"] }
        try await compareTransfer { _ in ["push", "not-a-remote", "main"] }
    }

    @Test func stdinMisuse() async throws {
        try await compareTransfer(input: Data("refs/heads/main\n".utf8)) { _ in
            ["push", "--stdin", "origin", "main"]
        }
    }

    private struct StagedTransfer {
        var repo: URL
        var bare: URL
        var files: [(name: String, bytes: Data, oid: String)]
    }

    private struct Side {
        var output: LFSSamePathOracle.Output
        var endpoint: String
    }

    /// `referencePush` runs system `git lfs push`, then our `fetch`. The other direction
    /// pushes with `GitCommand` and fetches with system git-lfs.
    private func roundTrip(referencePush: Bool) async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        try await LFSTestServer.withServer { server in
            let staged = try stage(oracle, server, files: [("a.dat", "alpha-lfs\n")], seed: false, excludeFirst: false)
            let pushed = try await invoke(
                ["push", "origin", "main"], in: staged.repo, reference: referencePush, oracle: oracle)
            #expect(pushed.status == 0, "\(pushed.stderr)\(pushed.stdout)")
            #expect(server.bytes(for: staged.files[0].oid) == staged.files[0].bytes)
            try oracle.git(["push", "--no-verify", "-q", "origin", "main"], in: staged.repo)
            let clone = oracle.root.appendingPathComponent("clone")
            try oracle.git(
                ["clone", "-q", staged.bare.path, clone.path], in: oracle.root,
                environment: ["GIT_LFS_SKIP_SMUDGE": "1"])
            try oracle.git(["config", "lfs.url", server.endpoint.absoluteString], in: clone)
            let fetched = try await invoke(["fetch"], in: clone, reference: !referencePush, oracle: oracle)
            #expect(fetched.status == 0, "\(fetched.stderr)\(fetched.stdout)")
            let oid = staged.files[0].oid
            let object = clone
                .appendingPathComponent(".git/lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)")
            #expect(FileManager.default.contents(atPath: object.path) == staged.files[0].bytes)
        }
    }

    private func compareTransfer(
        files: [(String, String)] = [("a.dat", "alpha-lfs\n")],
        seed: Bool = false, excludeFirst: Bool = false, input: Data = Data(),
        _ arguments: (StagedTransfer) -> [String]
    ) async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        var expected = try await side(
            oracle, files: files, seed: seed, excludeFirst: excludeFirst, reference: true, input: input, arguments)
        let actual = try await side(
            oracle, files: files, seed: seed, excludeFirst: excludeFirst, reference: false, input: input, arguments)
        // git-lfs logs the final meter line on a goroutine and returns without waiting.
        // A quiet run usually still flushes it. A busy one often exits first, leaving
        // stdout empty and status 0. Repeat the reference until that line arrives.
        if droppedMeter(expected.output, against: actual.output) {
            for _ in 0..<8 {
                let again = try await side(
                    oracle, files: files, seed: seed, excludeFirst: excludeFirst, reference: true, input: input,
                    arguments)
                if !again.output.stdout.isEmpty {
                    expected = again
                    break
                }
            }
        }
        let left = canonical(expected.output, endpoint: expected.endpoint)
        let right = canonical(actual.output, endpoint: actual.endpoint)
        #expect(left.stdout == right.stdout)
        #expect(left.stderr == right.stderr)
        #expect(left.status == right.status)
    }

    /// The reference printed nothing while our side printed one finished meter line.
    private func droppedMeter(
        _ reference: LFSSamePathOracle.Output, against actual: LFSSamePathOracle.Output
    ) -> Bool {
        guard reference.status == actual.status, reference.stdout.isEmpty,
              !actual.stdout.isEmpty else { return false }
        let text = LFSSamePathOracle.normalizeMeterSpeed(actual.stdout)
        return text.contains("LFS objects:") && text.hasSuffix(", done.\n")
    }

    private func side(
        _ oracle: LFSSamePathOracle, files: [(String, String)], seed: Bool, excludeFirst: Bool,
        reference: Bool, input: Data, _ arguments: (StagedTransfer) -> [String]
    ) async throws -> Side {
        try await LFSTestServer.withServer { server in
            let staged = try stage(oracle, server, files: files, seed: seed, excludeFirst: excludeFirst)
            let output = try await invoke(
                arguments(staged), in: staged.repo, reference: reference, oracle: oracle, input: input)
            return Side(output: output, endpoint: server.endpoint.absoluteString)
        }
    }

    private func invoke(
        _ arguments: [String], in directory: URL, reference: Bool, oracle: LFSSamePathOracle, input: Data = Data()
    ) async throws -> LFSSamePathOracle.Output {
        if reference {
            return try oracle.run(["lfs"] + arguments, in: directory, input: input, environment: prompt)
        }
        return try await oracle.ours(arguments, in: directory, input: input, environment: prompt)
    }

    private func stage(
        _ oracle: LFSSamePathOracle, _ server: LFSTestServer,
        files: [(String, String)], seed: Bool, excludeFirst: Bool
    ) throws -> StagedTransfer {
        for name in ["repo", "remote.git"] {
            let url = oracle.root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let bare = try oracle.repository("remote.git", bare: true)
        let repo = try oracle.repository("repo")
        try oracle.git(["remote", "add", "origin", bare.path], in: repo)
        try oracle.git(["config", "lfs.url", server.endpoint.absoluteString], in: repo)
        try oracle.track(["*.dat"], in: repo)
        var staged: [(name: String, bytes: Data, oid: String)] = []
        for (index, file) in files.enumerated() {
            let bytes = Data(file.1.utf8)
            try oracle.write(file.0, bytes, in: repo)
            try oracle.add(index == 0 ? [".gitattributes", file.0] : [file.0], in: repo)
            try oracle.commit(file.0, in: repo)
            let shown = try oracle.git(["show", "HEAD:\(file.0)"], in: repo)
            let line = try #require(shown.stdout.split(separator: "\n").first { $0.hasPrefix("oid sha256:") })
            staged.append((file.0, bytes, String(line.dropFirst("oid sha256:".count))))
            if excludeFirst, index == 0 {
                try oracle.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
            }
        }
        if seed {
            let objects = repo.appendingPathComponent(".git/lfs/objects")
            if FileManager.default.fileExists(atPath: objects.path) {
                try FileManager.default.removeItem(at: objects)
            }
            for file in staged { server.store(file.bytes, oid: file.oid) }
        }
        return StagedTransfer(repo: repo, bare: bare, files: staged)
    }

    /// The port and `expires_at` belong to that side's server. The speed field is the meter's
    /// only normalized token. Lock-verification text is left as git-lfs printed it.
    private func canonical(_ output: LFSSamePathOracle.Output, endpoint: String) -> LFSSamePathOracle.Output {
        func rewrite(_ text: String) -> String {
            let hosted = text.replacingOccurrences(of: endpoint, with: "<lfs>")
            let timed = hosted.replacing(
                /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})/,
                with: "<time>")
            return LFSSamePathOracle.normalizeMeterSpeed(timed)
        }
        return LFSSamePathOracle.Output(
            stdout: rewrite(output.stdout), stderr: rewrite(output.stderr), status: output.status)
    }
}
#endif
