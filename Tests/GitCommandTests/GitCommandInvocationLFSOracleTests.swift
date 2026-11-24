// `git -C` / `git -c` reach the LFS side of an invocation (issue #260):
// `git lfs env` and the clean filter `git add` runs read the directory and
// the configuration the invocation chose, and so does the first checkout of
// a clone, as git-lfs 3.7.1 under system git does.
#if os(macOS) || os(Linux)
import Foundation
import GitLFSTestSupport
import Testing

@Suite("git -C / -c reach git lfs (git-lfs 3.7.1)", .serialized,
       .enabled(if: LFSSamePathOracle.isAvailable, "git-lfs 3.7.1 is not on PATH"))
struct GitCommandInvocationLFSOracleTests {

    /// `git lfs env`, version lines aside, with its closing `GIT_*`
    /// environment lines compared as a set: their order is the process
    /// environment's, and system git adds its own `GIT_EXEC_PATH`.
    private struct LFSEnv: Equatable {
        let report: [String]
        let environment: Set<String>

        init(_ text: String) {
            let lines = LFSSamePathOracle.normalize(text).split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            let isEnvironment = { (line: String) in
                line.hasPrefix("GIT_") && !line.hasPrefix("GIT_EXEC_PATH=")
                    && line.prefix(while: { $0 != "=" }).allSatisfy { $0.isUppercase || $0 == "_" }
            }
            report = lines.filter { !isEnvironment($0) && !$0.hasPrefix("GIT_EXEC_PATH=") }
            environment = Set(lines.filter(isEnvironment))
        }
    }

    private func compareEnv(
        _ arguments: [String], _ oracle: GitInvocationOracle, environment: [String: String] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let expected = try await oracle.system(arguments, in: oracle.root, environment: environment)
        #expect(expected.status == 0, "\(expected)", sourceLocation: sourceLocation)
        for entry in GitInvocationOracle.Entry.allCases {
            let actual = try await oracle.port(entry, arguments, in: oracle.root, environment: environment)
            #expect(LFSEnv(actual.stdout) == LFSEnv(expected.stdout), "\(entry) \(arguments)",
                    sourceLocation: sourceLocation)
            #expect(actual.stderr == expected.stderr, "\(entry) \(arguments)", sourceLocation: sourceLocation)
            #expect(actual.status == expected.status, "\(entry) \(arguments)", sourceLocation: sourceLocation)
        }
    }

    @Test("git lfs env from the -C directory, with -c endpoints, storage and settings")
    func lfsEnv() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        try await oracle.gitOK(["lfs", "install", "--local"], in: repo)
        try FileManager.default.createDirectory(
            at: oracle.root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for arguments in [
            ["-C", "repo", "lfs", "env"],
            ["-C", "sub", "-C", "../repo", "lfs", "env"],
            ["-C", "repo", "-c", "lfs.url=https://lfs.example.com/objects", "-c", "lfs.storage=../store",
             "-c", "lfs.concurrenttransfers=3", "-c", "lfs.fetchrecentrefsdays=9", "lfs", "env"],
            ["-c", "remote.origin.url=https://example.com/one.git", "-c", "remote.origin.lfsurl=https://lfs.example.com/two",
             "-C", "repo", "lfs", "env"]
        ] {
            try await compareEnv(arguments, oracle)
        }
        // A relative GIT_DIR / GIT_WORK_TREE is read from the -C directory.
        try await compareEnv(["-C", "repo", "lfs", "env"], oracle,
                             environment: ["GIT_DIR": ".git", "GIT_WORK_TREE": "."])
        // The next invocation, from the root, is outside any repository again.
        try await compareEnv(["lfs", "env"], oracle)
    }

    @Test("git add's clean filter stores into the -c lfs.storage of the -C repository")
    func cleanFilter() async throws {
        let oracle = try GitInvocationOracle()
        defer { oracle.cleanup() }
        let repo = try await oracle.repository()
        try await oracle.gitOK(["lfs", "install", "--local"], in: repo)
        try await oracle.gitOK(["lfs", "track", "*.bin"], in: repo)
        try await oracle.gitOK(["add", ".gitattributes"], in: repo)
        try await oracle.gitOK(["commit", "-q", "-m", "track"], in: repo)
        try Data("large object\n".utf8).write(to: repo.appendingPathComponent("big.bin"))
        // Only the executable: it registers the process-global `lfs` filter
        // at startup in its own process, where registering it here would
        // race the other suites of this test process that do. It changes no
        // process directory either, so its filter sees `-C` / `-c` through
        // the same invocation Shell the embedded command gets.
        let store = oracle.root.appendingPathComponent("store")
        let state = { () async throws -> String in
            let staged = try await oracle.gitOK(["cat-file", "-p", ":big.bin"], in: repo)
            let stored = FileManager.default.enumerator(atPath: store.path)?.allObjects
                .compactMap { $0 as? String }.filter { $0.hasPrefix("objects/") && $0.count > 60 }.sorted() ?? []
            return staged + stored.joined(separator: "\n")
        }
        try await oracle.compare(
            ["-C", "repo", "-c", "lfs.storage=\(store.path)", "add", "big.bin"],
            in: oracle.root, fixture: oracle.root, state: state, entries: [.standalone])
    }

    @Test("clone's first checkout smudges from the -c / GIT_CONFIG_COUNT lfs.url")
    func cloneFirstCheckout() async throws {
        // The filter configuration git-lfs's `install` writes, so the
        // remote's only LFS endpoint is the one the invocation names.
        let oracle = try GitInvocationOracle(globalConfig: """
            [filter "lfs"]
            \tclean = git-lfs clean -- %f
            \tsmudge = git-lfs smudge -- %f
            \tprocess = git-lfs filter-process
            \trequired = true

            """)
        defer { oracle.cleanup() }
        let server = try await LFSTestServer.start()
        do {
            let seed = try await oracle.repository("seed")
            try await oracle.gitOK(["lfs", "install", "--local"], in: seed)
            try await oracle.gitOK(["config", "lfs.url", server.endpoint.absoluteString], in: seed)
            try await oracle.gitOK(["lfs", "track", "*.bin"], in: seed)
            let media = Data("first checkout media\n".utf8)
            try media.write(to: seed.appendingPathComponent("big.bin"))
            try await oracle.gitOK(["add", ".gitattributes", "big.bin"], in: seed)
            try await oracle.gitOK(["commit", "-q", "-m", "media"], in: seed)
            let bare = oracle.root.appendingPathComponent("remote.git")
            try await oracle.gitOK(["init", "-q", "--bare", "-b", "main", bare.path], in: oracle.root)
            try await oracle.gitOK(["push", "-q", bare.path, "main"], in: seed)

            let state = { () async throws -> String in
                let clone = oracle.root.appendingPathComponent("dest")
                let data = (try? Data(contentsOf: clone.appendingPathComponent("big.bin"))) ?? Data("<missing>".utf8)
                let status = try await oracle.system(["status", "--porcelain"], in: clone)
                return String(decoding: data, as: UTF8.self) + "status \(status.status): \(status.stdout)"
            }
            // Only the executable registers the `lfs` filter, process-wide,
            // as a host opts in to it (see `cleanFilter`).
            let url = server.endpoint.absoluteString
            let expected = try await oracle.compare(
                ["-c", "lfs.url=\(url)", "clone", "-q", bare.path, "dest"],
                in: oracle.root, state: state, entries: [.standalone])
            #expect(expected.status == 0, "\(expected)")
            try await oracle.compare(
                ["clone", "-q", bare.path, "dest"], in: oracle.root,
                environment: ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "lfs.url", "GIT_CONFIG_VALUE_0": url],
                state: state, entries: [.standalone])
            // The comparison means something only if the media arrived.
            _ = try await oracle.system(["-c", "lfs.url=\(url)", "clone", "-q", bare.path, "check"], in: oracle.root)
            #expect(try Data(contentsOf: oracle.root.appendingPathComponent("check/big.bin")) == media)
        } catch {
            await server.shutdown()
            throw error
        }
        await server.shutdown()
    }
}
#endif
