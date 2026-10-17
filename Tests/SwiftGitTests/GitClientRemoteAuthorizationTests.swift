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
