import NIOSSH
import Testing

@testable import SSHKit

@Suite("KnownHostsStore")
struct KnownHostsStoreTests {
    @Test func plainEntryMatchesListedHost() throws {
        let store = KnownHostsStore.parse(try SSHKitFixtures.contents("known_hosts_plain"), source: "known_hosts_plain")
        #expect(store.matchingEntries(forHost: "example.com").count == 1)
        #expect(store.matchingEntries(forHost: "nope.example.com").isEmpty)
    }

    @Test func plainEntrySupportsCommaSeparatedHostList() throws {
        let store = KnownHostsStore.parse(try SSHKitFixtures.contents("known_hosts_plain"), source: "known_hosts_plain")
        #expect(store.matchingEntries(forHost: "other.example.com").count == 1)
        #expect(store.matchingEntries(forHost: "10.0.0.1").count == 1)
    }

    @Test func hashedEntryMatchesByHMAC() throws {
        let store = KnownHostsStore.parse(try SSHKitFixtures.contents("known_hosts_hashed"), source: "known_hosts_hashed")
        #expect(store.matchingEntries(forHost: "example.com").count == 1)
        #expect(store.matchingEntries(forHost: "other.example.com").count == 1)
        #expect(store.matchingEntries(forHost: "10.0.0.1").count == 1)
        #expect(store.matchingEntries(forHost: "unknown.example.com").isEmpty)
    }

    @Test func plainAndHashedFixturesAgreeOnTheSameKey() throws {
        let plain = KnownHostsStore.parse(try SSHKitFixtures.contents("known_hosts_plain"), source: "plain")
        let hashed = KnownHostsStore.parse(try SSHKitFixtures.contents("known_hosts_hashed"), source: "hashed")

        let plainKey = plain.matchingEntries(forHost: "example.com").first?.publicKey
        let hashedKey = hashed.matchingEntries(forHost: "example.com").first?.publicKey
        #expect(plainKey == hashedKey)
    }

    @Test func recordNewHostRoundTripsThroughHashing() async throws {
        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var store = KnownHostsStore()
        let entry = store.recordNewHost("fresh.example.com", publicKey: identity.publicKey, hashed: true)

        #expect(entry.hostField.hasPrefix(HostKeyHashing.magic))
        #expect(store.matchingEntries(forHost: "fresh.example.com").first?.publicKey == identity.publicKey)
        #expect(store.matchingEntries(forHost: "other-host").isEmpty)
    }

    /// `match_hostname()` in `match.c` lowercases the connection host before comparing it against
    /// a plain `known_hosts` pattern, so case differences in how a hostname is typed/resolved don't
    /// cause a spurious "unknown host" failure.
    @Test func plainEntryMatchingIsCaseInsensitiveOnTheConnectionHost() throws {
        let store = KnownHostsStore.parse(try SSHKitFixtures.contents("known_hosts_plain"), source: "known_hosts_plain")
        #expect(store.matchingEntries(forHost: "EXAMPLE.COM").count == 1)
        #expect(store.matchingEntries(forHost: "Example.Com").count == 1)
    }

    /// Hashed entries are an HMAC over the literal connection-host bytes — no case folding applies.
    @Test func hashedEntryMatchingStaysCaseSensitive() throws {
        let store = KnownHostsStore.parse(try SSHKitFixtures.contents("known_hosts_hashed"), source: "known_hosts_hashed")
        #expect(store.matchingEntries(forHost: "EXAMPLE.COM").isEmpty)
    }

    /// Swift treats `\r\n` as a single `Character`, distinct from `"\n"` alone — splitting on a
    /// literal `"\n"` silently fails to split CRLF-terminated text at all, merging every line into
    /// one. Windows checks out text fixtures with CRLF line endings, which is exactly how this
    /// broke on `build-windows` CI: `other.example.com`/`10.0.0.1` stopped matching because the
    /// whole file collapsed into a single entry.
    @Test func parsingToleratesCRLFLineEndings() throws {
        let crlfContents = try SSHKitFixtures.contents("known_hosts_plain")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let store = KnownHostsStore.parse(crlfContents, source: "crlf")

        #expect(store.matchingEntries(forHost: "example.com").count == 1)
        #expect(store.matchingEntries(forHost: "other.example.com").count == 1)
        #expect(store.matchingEntries(forHost: "10.0.0.1").count == 1)
    }

    @Test func malformedLinesAreSkipped() {
        let store = KnownHostsStore.parse("not-enough-fields\n\n# comment\n@revoked marker ssh-ed25519 AAAA\n", source: "bad")
        #expect(store.entries.isEmpty)
    }
}
