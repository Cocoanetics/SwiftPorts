import Foundation
import Testing

@testable import SSHKit

@Suite("SSHConfig")
struct SSHConfigTests {
    private func loadSample() throws -> SSHConfig {
        .parse(try SSHKitFixtures.contents("ssh_config_sample"), source: "ssh_config_sample")
    }

    @Test func exactHostBlockWins() throws {
        let config = try self.loadSample()
        let resolved = try config.resolve(host: "example.com")

        #expect(resolved.hostName == "203.0.113.10")
        #expect(resolved.port == 2222)
        #expect(resolved.user == "alice")
        #expect(resolved.identityFiles == ["~/.ssh/id_ed25519"])
        #expect(resolved.identitiesOnly)
        #expect(resolved.strictHostKeyChecking == .acceptNew)
    }

    @Test func wildcardBlockAppliesToSubdomain() throws {
        let config = try self.loadSample()
        let resolved = try config.resolve(host: "foo.example.com")

        // Unset by any matching block, so it falls back to the requested host.
        #expect(resolved.hostName == "foo.example.com")
        #expect(resolved.user == "bob")
        #expect(resolved.identityFiles == ["~/.ssh/id_ecdsa"])
        // The trailing `Host !excluded.example.com *.example.com` block also matches.
        #expect(resolved.port == 9999)
        #expect(resolved.strictHostKeyChecking == .ask)
    }

    @Test func negatedPatternExcludesHostFromLaterBlock() throws {
        let config = try self.loadSample()
        let resolved = try config.resolve(host: "excluded.example.com")

        #expect(resolved.user == "bob")
        // Port 9999 lives in the block excluded.example.com is negated out of.
        #expect(resolved.port == 22)
    }

    @Test func unmatchedHostGetsDefaults() throws {
        let config = try self.loadSample()
        let resolved = try config.resolve(host: "unrelated.test")

        #expect(resolved.hostName == "unrelated.test")
        #expect(resolved.port == 22)
        #expect(resolved.user == nil)
        #expect(resolved.identityFiles == SSHHostConfig.defaultIdentityFiles)
        #expect(!resolved.identitiesOnly)
        #expect(resolved.userKnownHostsFile == SSHHostConfig.defaultUserKnownHostsFiles)
        #expect(resolved.strictHostKeyChecking == .ask)
    }

    @Test func unknownKeywordIsABadOption() throws {
        let config = SSHConfig.parse("TotallyMadeUpKeyword value\n", source: "bad.conf")
        #expect(throws: SSHError.self) {
            try config.resolve(host: "example.com")
        }
    }

    @Test func recognizedButUnimplementedKeywordIsTolerated() throws {
        let config = SSHConfig.parse("ForwardAgent yes\nProxyCommand nc %h %p\n", source: "tolerant.conf")
        let resolved = try config.resolve(host: "example.com")
        #expect(resolved.hostName == "example.com")
    }

    @Test func matchBlockNeverApplies() throws {
        let config = SSHConfig.parse("Match host example.com\nPort 1234\n", source: "match.conf")
        let resolved = try config.resolve(host: "example.com")
        #expect(resolved.port == 22)
    }

    @Test func equalsSeparatorIsAccepted() throws {
        let config = SSHConfig.parse("Host x\nPort=2200\n", source: "eq.conf")
        let resolved = try config.resolve(host: "x")
        #expect(resolved.port == 2200)
    }

    @Test func missingConfigFileResolvesToDefaults() async throws {
        let config = try await SSHConfig.load(path: "/nonexistent/path/to/ssh_config_\(UUID().uuidString)")
        let resolved = try config.resolve(host: "example.com")
        #expect(resolved.hostName == "example.com")
        #expect(resolved.strictHostKeyChecking == .ask)
    }
}
