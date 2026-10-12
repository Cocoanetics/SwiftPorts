import Testing

@testable import SSHKit

@Suite("SSHPatternList")
struct SSHPatternListTests {
    @Test func exactMatch() {
        #expect(SSHPatternList.matchesGlob(host: "example.com", pattern: "example.com"))
        #expect(!SSHPatternList.matchesGlob(host: "example.com", pattern: "example.org"))
    }

    @Test func starWildcard() {
        #expect(SSHPatternList.matchesGlob(host: "foo.example.com", pattern: "*.example.com"))
        #expect(!SSHPatternList.matchesGlob(host: "example.com", pattern: "*.example.com"))
        #expect(SSHPatternList.matchesGlob(host: "anything", pattern: "*"))
    }

    @Test func questionMarkWildcard() {
        #expect(SSHPatternList.matchesGlob(host: "host1", pattern: "host?"))
        #expect(!SSHPatternList.matchesGlob(host: "host12", pattern: "host?"))
    }

    @Test func commaListFirstMatchWins() {
        #expect(SSHPatternList.matches(host: "bar2", tokens: ["foo", "!bar", "bar2"]))
    }

    @Test func negationShortCircuitsToNoMatch() {
        #expect(!SSHPatternList.matches(host: "bar", tokens: ["foo", "!bar"]))
    }

    @Test func noTokenMatchesIsFalse() {
        #expect(!SSHPatternList.matches(host: "example.com", tokens: ["other.com"]))
    }
}
