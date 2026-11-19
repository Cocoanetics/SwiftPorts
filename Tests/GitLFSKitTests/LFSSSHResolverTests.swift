import Foundation
import Testing
@testable import GitLFSKit

@Suite("LFS SSH authentication")
struct LFSSSHResolverTests {
    private func response(_ json: String, ttl: Int = 0) throws -> LFSSSHAuthResponse {
        var decoded = try JSONDecoder().decode(LFSSSHAuthResponse.self, from: Data(json.utf8))
        decoded.received(at: Date(timeIntervalSince1970: 1_700_000_000), defaultTTL: ttl)
        return decoded
    }

    @Test("response JSON and expiration follow git-lfs TimeAtOrIn")
    func expiration() throws {
        let decoded = try response("""
            {"href":"https://lfs.example/repo","header":{"Authorization":"RemoteAuth token"},
             "expires_at":"2023-11-14T22:13:30.123Z","expires_in":60}
            """)
        #expect(decoded.href == "https://lfs.example/repo")
        #expect(decoded.header == ["Authorization": "RemoteAuth token"])
        #expect(decoded.expiresAt?.timeIntervalSince1970 == 1_700_000_010.123)
        #expect(decoded.expiry?.timeIntervalSince1970 == 1_700_000_060)
        #expect(!decoded.expired(at: Date(timeIntervalSince1970: 1_700_000_055)))
        #expect(decoded.expired(at: Date(timeIntervalSince1970: 1_700_000_056)))
        #expect(try response("{}").expiry == nil)
        #expect(try response("{}", ttl: -1).expiry == nil)
        #expect(try response("{}", ttl: 60).expiry?.timeIntervalSince1970 == 1_700_000_060)
        #expect(try response(#"{"expires_in":-1}"#).expired(at: Date(timeIntervalSince1970: 1_700_000_000)))
        let absolute = try response(#"{"expires_at":"2023-11-14T23:13:30+01:00"}"#, ttl: 600)
        #expect(absolute.expiry?.timeIntervalSince1970 == 1_700_000_010)
        #expect(try response(#"{"expires_at":"0001-01-01T00:00:00Z"}"#).expiry == nil)
        #expect(throws: DecodingError.self) { try response(#"{"expires_at":"invalid"}"#) }
        #expect(throws: DecodingError.self) { try response(#"{"header":{"Authorization":42}}"#) }
    }

    @Test("remote command uses git-lfs ShellQuoteSingle", arguments: [
        ("repo.git", "repo.git"), ("/org/my repo.git", "'/org/my repo.git'"),
        ("o'neil.git", "'o'\\''neil.git'"), ("wow!.git", "'wow!.git'"),
        ("$(touch bad);repo", "'$(touch bad);repo'"), ("", "''"),
        ("/~/repo.git", "'/~/repo.git'"), ("répo.git", "'répo.git'")
    ])
    func command(path: String, quoted: String) {
        for (user, port) in [("", ""), ("git", "2222")] {
            var endpoint = LFSEndpoint(ssh: LFSSSHMetadata(user: user, host: "alias", port: port, path: path))
            #expect(LFSSSHResolver.remoteCommand(endpoint, method: "GET") == "git-lfs-authenticate \(quoted) download")
            #expect(LFSSSHResolver.remoteCommand(endpoint, method: "POST") == "git-lfs-authenticate \(quoted) upload")
            endpoint.operation = "download"
            #expect(LFSSSHResolver.remoteCommand(endpoint, method: "POST") == "git-lfs-authenticate \(quoted) download")
        }
    }

    @Test("cache separates operations, refreshes early, and retries failures")
    func cache() async throws {
        let host = IsolatedLFSHost()
        try await host.run {
            let fixture = try await LFSFixture.make(host, "ssh-cache", config: [("lfs.ssh.retries", "1")])
            let finder = await LFSEndpointFinder(fixture.client)
            let calls = SSHAuthCalls()
            let resolver = LFSSSHResolver(finder: finder, now: { calls.date }, authenticate: { _, _ in
                let count = calls.record()
                if count == 1 { throw LFSClientError("try again") }
                return Data("{\"href\":\"https://lfs.example/\(count)\",\"expires_in\":60}".utf8)
            })
            var endpoint = LFSEndpoint(
                ssh: LFSSSHMetadata(host: "alias", path: "repo", userAndHost: "alias"), operation: "download")
            let first = try await resolver.resolve(endpoint, method: "POST")
            #expect(first.href == "https://lfs.example/2")
            #expect(try await resolver.resolve(endpoint, method: "POST").href == first.href)
            endpoint.operation = "upload"
            _ = try await resolver.resolve(endpoint, method: "PUT")
            #expect(calls.count == 3)
            calls.advance(56)
            #expect(try await resolver.resolve(endpoint, method: "POST").href == "https://lfs.example/4")
        }
    }

    @Test("scp aliases retain relative paths and ssh URLs retain absolute paths")
    func endpointPaths() async throws {
        let host = IsolatedLFSHost()
        try await host.run {
            for (index, remote) in ["alias:org/repo.git", "git@alias:org/repo.git",
                                     "ssh://git@alias:2222/org/repo.git"].enumerated() {
                let fixture = try await LFSFixture.make(host, "ssh-path-\(index)", remotes: [("origin", remote)])
                let finder = await LFSEndpointFinder(fixture.client)
                let endpoint = finder.endpoint(operation: "download", remote: "origin")
                #expect(endpoint.ssh.path == (index == 2 ? "/org/repo.git" : "org/repo.git"))
                #expect(endpoint.ssh.host == "alias")
                #expect(endpoint.ssh.port == (index == 2 ? "2222" : ""))
                #expect(endpoint.ssh.user == (index == 0 ? "" : "git"))
            }
        }
    }

    @Test("a malformed response is not cached")
    func malformedResponse() async throws {
        let host = IsolatedLFSHost()
        try await host.run {
            let fixture = try await LFSFixture.make(host, "bad-json", config: [("lfs.ssh.retries", "0")])
            let calls = SSHAuthCalls()
            let resolver = LFSSSHResolver(
                finder: await LFSEndpointFinder(fixture.client), now: { calls.date }, authenticate: { _, _ in
                    Data((calls.record() == 1 ? "invalid" : "{}").utf8)
                })
            let endpoint = LFSEndpoint(ssh: LFSSSHMetadata(host: "alias", userAndHost: "alias"))
            await #expect(throws: DecodingError.self) { try await resolver.resolve(endpoint, method: "GET") }
            _ = try await resolver.resolve(endpoint, method: "GET")
            _ = try await resolver.resolve(endpoint, method: "GET")
            #expect(calls.count == 2)
        }
    }

    @Test("cachecredentials false and default token TTL")
    func cacheConfiguration() async throws {
        let host = IsolatedLFSHost()
        try await host.run {
            for (index, cache) in ["true", "false"].enumerated() {
                let fixture = try await LFSFixture.make(host, "ttl-\(index)", config: [
                    ("lfs.cachecredentials", cache), ("lfs.defaulttokenttl", "60")])
                let calls = SSHAuthCalls()
                let resolver = LFSSSHResolver(
                    finder: await LFSEndpointFinder(fixture.client), now: { calls.date }, authenticate: { _, _ in
                    _ = calls.record()
                    return Data("{}".utf8)
                })
                let endpoint = LFSEndpoint(ssh: LFSSSHMetadata(host: "alias", userAndHost: "alias"))
                _ = try await resolver.resolve(endpoint, method: "GET")
                _ = try await resolver.resolve(endpoint, method: "GET")
                #expect(calls.count == (cache == "true" ? 1 : 2))
                calls.advance(56)
                _ = try await resolver.resolve(endpoint, method: "GET")
                #expect(calls.count == (cache == "true" ? 2 : 3))
            }
        }
    }

    @Test("sshtransfer always disables authentication, with URL-specific precedence")
    func transferMode() async throws {
        let host = IsolatedLFSHost()
        try await host.run {
            let fixture = try await LFSFixture.make(host, "mode", config: [
                ("lfs.sshtransfer", "never"), ("lfs.ssh://alias/repo.sshtransfer", "always")])
            let resolver = LFSSSHResolver(finder: await LFSEndpointFinder(fixture.client))
            let endpoint = LFSEndpoint(originalURL: "ssh://alias/repo")
            await #expect(throws: LFSClientError("git-lfs-authenticate has been disabled by request")) {
                try await resolver.resolve(endpoint, method: "POST")
            }
            #expect(try await resolver.resolve(LFSEndpoint(), method: "GET").href.isEmpty)
        }
    }
}
