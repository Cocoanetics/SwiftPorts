import ArgumentParser
import Foundation
import Testing
import GitHub
@testable import GhCommand

/// Pins `gh auth status` output to upstream gh's format
/// (pkg/cmd/auth/status/status.go). ANSI is inert here — test
/// runners aren't color TTYs — so expectations are plain strings.
struct AuthStatusRenderingTests {

    // MARK: maskToken (upstream keeps the prefix through the last `_`)

    @Test func masksClassicTokenKeepingPrefix() {
        let masked = AuthStatusEntry.maskToken("gho_" + String(repeating: "a", count: 36))
        #expect(masked == "gho_" + String(repeating: "*", count: 36))
    }

    @Test func masksFineGrainedTokenThroughLastUnderscore() {
        #expect(AuthStatusEntry.maskToken("github_pat_abcdef") == "github_pat_******")
    }

    @Test func masksTokenWithoutUnderscoreEntirely() {
        #expect(AuthStatusEntry.maskToken("abcd1234") == "********")
    }

    // MARK: displayScopes / expectScopes

    @Test func quotesAndJoinsScopes() {
        #expect(AuthStatusEntry.displayScopes(["gist", "read:org", "repo"])
            == "'gist', 'read:org', 'repo'")
    }

    @Test func rendersNoneForEmptyOrAbsentScopes() {
        #expect(AuthStatusEntry.displayScopes([]) == "none")
        #expect(AuthStatusEntry.displayScopes(nil) == "none")
    }

    @Test func expectsScopesOnlyForClassicTokenPrefixes() {
        #expect(AuthStatusEntry.expectScopes("gho_abc"))
        #expect(AuthStatusEntry.expectScopes("ghp_abc"))
        // Masking preserves the prefix, so the check still applies.
        #expect(AuthStatusEntry.expectScopes("gho_***"))
        #expect(!AuthStatusEntry.expectScopes("github_pat_abc"))
        #expect(!AuthStatusEntry.expectScopes("ghs_abc"))
    }

    // MARK: entry rendering

    private func entry(
        state: AuthStatusEntry.State,
        login: String? = "odrobnik",
        sourceLabel: String = "keyring",
        token: String = "gho_" + String(repeating: "*", count: 36)
    ) -> AuthStatusEntry {
        AuthStatusEntry(
            state: state, host: "github.com", login: login,
            sourceLabel: sourceLabel, gitProtocol: "ssh", token: token)
    }

    @Test func rendersSuccessEntryLikeUpstream() {
        let lines = entry(state: .success(scopes: ["gist", "read:org", "repo"])).lines
        #expect(lines == [
            "  ✓ Logged in to github.com account odrobnik (keyring)",
            "  - Active account: true",
            "  - Git operations protocol: ssh",
            "  - Token: gho_************************************",
            "  - Token scopes: 'gist', 'read:org', 'repo'",
        ])
    }

    @Test func successRendersNoneForScopelessClassicToken() {
        let lines = entry(state: .success(scopes: [])).lines
        #expect(lines.last == "  - Token scopes: none")
    }

    @Test func successOmitsScopesLineForFineGrainedToken() {
        let lines = entry(
            state: .success(scopes: nil),
            token: "github_pat_" + String(repeating: "*", count: 12)
        ).lines
        #expect(lines.count == 4)
        #expect(!lines.contains { $0.contains("Token scopes") })
    }

    @Test func rendersInvalidKeyringEntryWithReauthHints() {
        let lines = entry(state: .invalidToken).lines
        #expect(lines == [
            "  X Failed to log in to github.com account odrobnik (keyring)",
            "  - Active account: true",
            "  - The token in keyring is invalid.",
            "  - To re-authenticate, run: gh auth login -h github.com",
            "  - To forget about this account, run: gh auth logout -h github.com -u odrobnik",
        ])
    }

    @Test func rendersInvalidEnvEntryWithoutHints() {
        let lines = entry(
            state: .invalidToken, login: nil, sourceLabel: "GH_TOKEN").lines
        #expect(lines == [
            "  X Failed to log in to github.com using token (GH_TOKEN)",
            "  - Active account: true",
            "  - The token in GH_TOKEN is invalid.",
        ])
    }

    @Test func rendersTimeoutEntry() {
        let lines = entry(state: .timeout).lines
        #expect(lines == [
            "  X Timeout trying to log in to github.com account odrobnik (keyring)",
            "  - Active account: true",
        ])
    }

    // MARK: token-source labels (upstream buildEntry)

    @Test func statusLabelsMatchUpstream() {
        #expect(TokenSource.ghTokenEnv.ghStatusLabel == "GH_TOKEN")
        #expect(TokenSource.githubTokenEnv.ghStatusLabel == "GITHUB_TOKEN")
        #expect(TokenSource.secretStore.ghStatusLabel == "keyring")
        #expect(TokenSource.hostsFile.ghStatusLabel.hasSuffix("hosts.yml"))
    }

    // MARK: the no-token gate (upstream authHelp + exitAuth = 4)

    @Test func apiClientGateRefusesWithoutToken() {
        #expect(throws: ExitCode(4)) {
            try CommandContext.requireAuthentication(
                Configuration(host: "github.com", token: nil))
        }
    }

    @Test func apiClientGatePassesWithToken() throws {
        try CommandContext.requireAuthentication(
            Configuration(host: "github.com", token: "gho_x"))
    }
}
