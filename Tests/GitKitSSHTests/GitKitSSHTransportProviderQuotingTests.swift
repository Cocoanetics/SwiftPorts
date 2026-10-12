// Covers the Codex review finding on #117: a repository path containing a
// single quote must not be able to terminate the shell quoting around the
// remote `git-upload-pack`/`git-receive-pack`/`git-upload-archive` command
// and inject arbitrary shell syntax. `shellQuote` mirrors git's own
// `sq_quote_buf` (`quote.c`).
import Testing
@testable import GitKitSSH

@Suite struct GitKitSSHTransportProviderQuotingTests {

    @Test func plainPathIsUnchanged() {
        #expect(GitKitSSHTransportProvider.shellQuote("/repo.git") == "'/repo.git'")
    }

    @Test func pathWithSpacesIsWrappedAsIs() {
        #expect(GitKitSSHTransportProvider.shellQuote("/path with spaces/repo.git") == "'/path with spaces/repo.git'")
    }

    @Test func embeddedSingleQuoteIsEscaped() {
        #expect(GitKitSSHTransportProvider.shellQuote("/repo's/path.git") == "'/repo'\\''s/path.git'")
    }

    @Test func embeddedBangIsEscaped() {
        #expect(GitKitSSHTransportProvider.shellQuote("/repo!.git") == "'/repo'\\!'.git'")
    }

    @Test func maliciousPathCannotEscapeTheQuoting() {
        let malicious = "/repo'; rm -rf /; echo '"
        let quoted = GitKitSSHTransportProvider.shellQuote(malicious)
        // Every embedded `'` is escaped (closed, literal, reopened) rather than left bare,
        // so the injected `; rm -rf /; echo` never lands outside the surrounding quotes.
        #expect(quoted == "'/repo'\\''; rm -rf /; echo '\\'''")
    }
}
