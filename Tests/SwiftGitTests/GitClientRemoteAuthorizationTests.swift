import Foundation
import Testing
import ShellKit
@testable import SwiftGit

/// Issue #122: `git clone` authorizes scp-like remotes by their host, not as host-less URLs.
@Suite struct GitClientRemoteAuthorizationTests {

    @Test func scpLikeRemotesAuthorizeAsSSHURLs() throws {
        let cases: [(remote: String, authorized: String, host: String)] = [
            ("git@github.com:Cocoanetics/SwiftPorts.git", "ssh://git@github.com/Cocoanetics/SwiftPorts.git", "github.com"),
            ("myhost:repo.git", "ssh://myhost/repo.git", "myhost"),
            ("myhost:/srv/git/repo.git", "ssh://myhost/srv/git/repo.git", "myhost"),
            // Bracketed IPv6 hosts — `URL(string:)` percent-encodes these,
            // and the address's own colons mustn't end the host.
            ("git@[::1]:repo.git", "ssh://git@[::1]/repo.git", "::1"),
            ("[::1]:repo.git", "ssh://[::1]/repo.git", "::1"),
            ("git@[fe80::1%en0]:repo.git", "ssh://git@[fe80::1%25en0]/repo.git", "fe80::1%en0"),
        ]
        for testCase in cases {
            let remote = try #require(URL(string: testCase.remote))
            let url = GitClient.authorizationURL(forRemote: remote)
            #expect(url.absoluteString == testCase.authorized)
            #expect(url.host == testCase.host)
        }
    }

    @Test func urlsAndLocalPathsPassThrough() throws {
        for remote in [
            "https://github.com/Cocoanetics/SwiftPorts.git",
            "ssh://git@github.com/Cocoanetics/SwiftPorts.git",
            "file:///srv/git/repo.git",
            "relative/path/repo.git",
        ] {
            let url = try #require(URL(string: remote))
            #expect(GitClient.authorizationURL(forRemote: url) == url)
        }
        let local = URL(fileURLWithPath: "/srv/git/repo.git")
        #expect(GitClient.authorizationURL(forRemote: local) == local)
    }

    /// The gate now names the host — instead of "non-file URL has no host to authorize", which no
    /// host allowlist could ever pass.
    @Test func cloneOfScpLikeRemoteIsJudgedByHost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientRemoteAuthorizationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = Shell(environment: Environment(), sandbox: Sandbox.rooted(at: root))

        let denial = await #expect(throws: Sandbox.Denial.self) {
            try await shell.withCurrent {
                try await GitClient(workingDirectory: root).clone(
                    url: try #require(URL(string: "git@example.invalid:owner/repo.git")),
                    directory: root.appendingPathComponent("repo"))
            }
        }
        #expect(denial?.reason == "host 'example.invalid' is not in the sandbox allowlist")
    }

    /// A configured remote is judged like a typed one, by where libgit2
    /// connects: its URL after `insteadOf`, a push's push URL, a path as
    /// the process reads it. Before, only typed remotes were gated.
    @Test func configuredRemotesAreJudgedByWhereTheyConnect() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientRemoteAuthorizationTests-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientRemoteAuthorizationTests-outside-\(UUID().uuidString)")
        defer { [root, outside].forEach { try? FileManager.default.removeItem(at: $0) } }
        let repo = root.appendingPathComponent("repo")
        try Repository.initialize(at: repo, initialBranch: "main")
        let inside = root.appendingPathComponent("inside.git")
        try Repository.initialize(at: inside, bare: true, initialBranch: "main")
        try Repository.initialize(at: outside, bare: true, initialBranch: "main")
        let shell = Shell(environment: Environment(workingDirectory: repo.path), sandbox: Sandbox.rooted(at: root))

        try await shell.withCurrent {
            let client = GitClient(workingDirectory: repo)
            try await client.addRemote(name: "web", remote: "https://example.invalid/owner/repo.git")
            try await client.addRemote(name: "mirror", remote: inside.path)
            try await client.configSet("remote.mirror.pushurl", "https://example.invalid/mirror.git")
            try await client.addRemote(name: "short", remote: "short:repo.git")
            try await client.configSet("url.https://example.invalid/.insteadOf", "short:")
            try await client.addRemote(name: "outside", remote: outside.path)

            func denial(_ body: () async throws -> Void) async -> Sandbox.Denial? {
                do { try await body() } catch let denial as Sandbox.Denial { return denial } catch {}
                return nil
            }
            let hostDenied = "host 'example.invalid' is not in the sandbox allowlist"
            #expect(await denial { try await client.fetch(remote: "web", refspecs: [], depth: nil) }?.reason
                    == hostDenied)
            #expect(await denial { try await client.fetch(remote: "short", refspecs: [], depth: nil) }?.reason
                    == hostDenied)
            // The mirror fetches from inside the sandbox, but pushes out.
            #expect(await denial { try await client.fetch(remote: "mirror", refspecs: [], depth: nil) } == nil)
            #expect(await denial {
                try await client.push(remote: "mirror", refspecs: ["HEAD:refs/heads/x"], setUpstream: false)
            }?.reason == hostDenied)
            #expect(await denial { try await client.fetch(remote: "outside", refspecs: [], depth: nil) } != nil)

            // A scheme no transport handles is refused, as git refuses
            // it, rather than taken for SSH.
            try await client.addRemote(name: "weird", remote: "foo://example.invalid/r.git")
            await #expect(throws: UnsupportedTransportError.noHelper(scheme: "foo")) {
                try await client.fetch(remote: "weird", refspecs: [], depth: nil)
            }

            // A typed remote is judged after libgit2's insteadOf too: a
            // scp-style `short:` and a path inside the sandbox both lead
            // out to the blocked host.
            #expect(await denial { try await client.fetch(remote: "short:repo.git", refspecs: [], depth: nil) }?
                .reason == hostDenied)
            try await client.configSet("url.https://example.invalid/.insteadOf", inside.path)
            #expect(await denial { try await client.fetch(remote: inside.path, refspecs: [], depth: nil) }?
                .reason == hostDenied)
        }
    }

    @Test func cloneOfBracketedIPv6RemoteIsJudgedByHost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientRemoteAuthorizationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = Shell(environment: Environment(), sandbox: Sandbox.rooted(at: root))

        let denial = await #expect(throws: Sandbox.Denial.self) {
            try await shell.withCurrent {
                try await GitClient(workingDirectory: root).clone(
                    url: try #require(URL(string: "git@[::1]:repo.git")),
                    directory: root.appendingPathComponent("repo"))
            }
        }
        #expect(denial?.reason == "host '::1' is not in the sandbox allowlist")
    }
}
