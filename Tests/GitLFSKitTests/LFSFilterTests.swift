import Foundation
import Testing
import ForgeKit
import SwiftGit
import ShellKit
@testable import GitLFSKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("LFS filter registration and callback isolation", .serialized, .timeLimit(.minutes(1)))
struct LFSFilterTests {
    private let endpoint = "https://filter.example/repo.git/info/lfs"

    @Test("one opt-in lifecycle covers gating, checkout queries, 401 writes and revocation")
    func lifecycle() async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        #expect(!GitFilters.isRegistered("lfs"))
        try await host.run {
            let made = try await fixture(host)
            _ = await LFSClient(git: made.client)
            var options = FilterOptions()
            options.local = true
            options.skipRepo = true
            _ = try await options.install(made.client)
            #expect(!GitFilters.isRegistered("lfs"))
        }

        try GitLFSKit.installFilter()
        defer { try? GitLFSKit.uninstallFilter() }
        #expect(GitFilters.isRegistered("lfs"))
        #expect(throws: (any Error).self) { try GitLFSKit.installFilter() }

        let observations = LFSFilterObservation()
        let probe = "lfs-callback-" + UUID().uuidString
        let factory: GitFilter.StreamFactory = { source, output in
            guard observations.watches(source.gitDirectory) else { return nil }
            let stream = try GitLFSKit.stream(source, output)
            let enabled = stream != nil
            let context = try GitFilterOperationContext.capture()
            try BlockingBridge.runBlocking {
                try await context.withSource(source) { git in
                    guard try await git.canResolveRef("HEAD") else { return }
                    observations.record(source.direction, enabled: enabled, client: git)
                    #expect(try await git.gitDir().map { URL(fileURLWithPath: $0).standardizedFileURL }
                        == source.gitDirectory.standardizedFileURL)
                    #expect(try await git.toplevel().map { URL(fileURLWithPath: $0).standardizedFileURL }
                        == source.workingDirectory?.standardizedFileURL)
                    #expect(try await git.configGet("test.environment") == Shell.env("FILTER_TEST_VALUE"))
                    #expect(try await git.catFileBlob("HEAD:a.lfs") == Data("payload\n".utf8))
                    #expect(try await git.resolveOID("HEAD").count == 40)
                    try await deniedInclude(git)
                    // Git mutations cannot use the callback metadata lease.
                    await #expect(throws: (any Error).self) { try await git.add(paths: ["a.lfs"]) }
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.protocolClasses = [LFSFilterURLProtocol.self]
                    let lfs = await LFSClient(git: git, credentials: git.credentials, configuration: configuration)
                    #expect(lfs.finder.endpoint(operation: "download").url == endpoint)
                    _ = try await lfs.data(for: URLRequest(url: URL(string: endpoint + "/objects/batch")!))
                    #expect(try await git.configGet("lfs.\(endpoint).access") == "basic")
                    // Repeat the actual 401 path for every callback.
                    _ = try await git.configUnset("lfs.\(endpoint).access")
                }
            }
            return stream
        }
        try GitFilters.register(name: probe, attributes: "filter=lfs", GitFilter(clean: factory, smudge: factory))
        defer { try? GitFilters.unregister(name: probe) }

        // Two independent shells and providers must survive the bridge.
        for token in ["first", "second"] {
            let isolated = IsolatedLFSHost()
            observations.watch(isolated.root)
            defer { try? FileManager.default.removeItem(at: isolated.root) }
            var variables = isolated.variables
            variables.merge([
                "FILTER_TEST_VALUE": token, "GIT_CONFIG_COUNT": "1",
                "GIT_CONFIG_KEY_0": "test.environment", "GIT_CONFIG_VALUE_0": token
            ]) { _, value in value }
            let shell = Shell(environment: Environment(variables: variables, workingDirectory: isolated.root.path))
            let denied = isolated.root.appendingPathComponent("denied.cfg")
            try Data("[test]\nsecret = must-not-read\n".utf8).write(to: denied)
            shell.environment["FILTER_DENIED_INCLUDE"] = denied.path
            shell.sandbox = isolated.sandbox(refusing: { $0.standardizedFileURL == denied.standardizedFileURL })
            try await shell.withCurrent {
                let made = try await fixture(isolated, token: token)
                try await gating(made, observations: observations)
                let linked = isolated.root.appendingPathComponent("linked")
                try await made.client.worktreeAdd(path: linked, branch: "linked")
                let linkedClient = SwiftGit.GitClient(workingDirectory: linked, credentials: made.client.credentials)
                try await restore(linkedClient, directory: linked)
                #expect(!observations.take().isEmpty)
                let destination = isolated.root.appendingPathComponent("clone")
                let cloner = SwiftGit.GitClient(workingDirectory: isolated.root, credentials: made.client.credentials)
                // Clone's source needs filter config in the shell's effective
                // config, since its destination has only just been created.
                shell.environment["GIT_CONFIG_COUNT"] = "3"
                shell.environment["GIT_CONFIG_KEY_1"] = "filter.lfs.process"
                shell.environment["GIT_CONFIG_VALUE_1"] = "git-lfs filter-process"
                shell.environment["GIT_CONFIG_KEY_2"] = "lfs.url"
                shell.environment["GIT_CONFIG_VALUE_2"] = endpoint
                try await cloner.clone(url: made.directory, directory: destination)
                #expect(!observations.take().isEmpty)
            }
            let expired = try #require(observations.client)
            await #expect(throws: (any Error).self) { _ = try await expired.configGet("lfs.url") }
        }
        try GitLFSKit.uninstallFilter()
        #expect(!GitFilters.isRegistered("lfs"))
    }

    private func fixture(_ host: IsolatedLFSHost, token: String = "setup") async throws
        -> (directory: URL, client: SwiftGit.GitClient) {
        let made = try await LFSFixture.make(host, "source", config: [("lfs.url", endpoint)])
        let client = SwiftGit.GitClient(workingDirectory: made.directory, credentials: { _, _, _ in
            #expect(Shell.env("FILTER_TEST_VALUE") == token)
            return .userPassword(username: "git", password: token)
        })
        try Data("*.lfs filter=lfs -text\n".utf8).write(to: made.directory.appendingPathComponent(".gitattributes"))
        try Data("payload\n".utf8).write(to: made.directory.appendingPathComponent("a.lfs"))
        try Data("other\n".utf8).write(to: made.directory.appendingPathComponent("b.txt"))
        try await client.add(paths: [".gitattributes", "a.lfs", "b.txt"])
        _ = try await client.commit(message: "files", author: nil, allowEmpty: false)
        return (made.directory, client)
    }

    private func restore(_ git: SwiftGit.GitClient, directory: URL) async throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.lfs"))
        try await git.checkoutPaths(["a.lfs"])
        #expect(try Data(contentsOf: directory.appendingPathComponent("a.lfs")) == Data("payload\n".utf8))
    }

    private func deniedInclude(_ git: SwiftGit.GitClient) async throws {
        let denied = try #require(Shell.env("FILTER_DENIED_INCLUDE"))
        let common = try #require(try await git.commonDir())
        let file = URL(fileURLWithPath: common).appendingPathComponent("config")
        let original = try Data(contentsOf: file)
        defer { try? original.write(to: file) }
        var including = original
        // Forward slashes and quoting work with git config on Windows too.
        let path = denied.replacingOccurrences(of: "\\", with: "/")
        including.append(Data("\n[include]\npath = \"\(path)\"\n".utf8))
        try including.write(to: file)
        await #expect(throws: Sandbox.Denial.self) { _ = try await git.configGet("test.secret") }
    }

    private func gating(
        _ made: (directory: URL, client: SwiftGit.GitClient), observations: LFSFilterObservation
    ) async throws {
        _ = observations.take()
        for key in ["", "clean", "smudge", "process"] {
            for previous in ["clean", "smudge", "process"] {
                _ = try await made.client.configUnset("filter.lfs.\(previous)")
            }
            if !key.isEmpty { try await made.client.configSet("filter.lfs.\(key)", "git-lfs " + key) }
            try await restore(made.client, directory: made.directory)
            let smudges = observations.take().filter { $0.0 == .smudge }
            #expect(!smudges.isEmpty)
            #expect(smudges.allSatisfy { $0.1 == (key == "smudge" || key == "process") })
            try Data("payload\n".utf8).write(to: made.directory.appendingPathComponent("a.lfs"))
            try await made.client.add(paths: ["a.lfs"])
            let cleans = observations.take().filter { $0.0 == .clean }
            #expect(!cleans.isEmpty)
            #expect(cleans.allSatisfy { $0.1 == (key == "clean" || key == "process") })
        }
        try await made.client.checkoutPaths(["b.txt"])
        #expect(observations.take().isEmpty)
    }
}
