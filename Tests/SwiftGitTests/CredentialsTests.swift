import Foundation
import Testing
import libgit2
@testable import SwiftGit

@Suite("Credentials bridge")
struct CredentialsTests {

    init() {
        // The credential constructors call libgit2 internals; instantiate
        // the client once to drive Libgit2.ensureInitialized().
        _ = GitClient(workingDirectory: FileManager.default.temporaryDirectory)
    }

    /// Drive the `withCredentialPayload` trampoline directly to verify
    /// it (a) calls our Swift provider with the right inputs, and
    /// (b) builds a non-NULL `git_credential` from each `Credentials`
    /// case. We never need a real transport.
    private func acquire(
        url: String,
        usernameFromURL: String? = nil,
        allowed: UInt32 = UInt32(GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue)
            | UInt32(GIT_CREDENTIAL_SSH_KEY.rawValue)
            | UInt32(GIT_CREDENTIAL_USERNAME.rawValue)
            | UInt32(GIT_CREDENTIAL_DEFAULT.rawValue),
        provider: @escaping CredentialProvider
    ) -> (Int32, UnsafeMutablePointer<git_credential>?) {
        var out: UnsafeMutablePointer<git_credential>?
        let rc: Int32 = withCredentialPayload(provider) { cb, payload in
            guard let cb else { return -1 }
            return url.withCString { urlPtr -> Int32 in
                if let usernameFromURL {
                    return usernameFromURL.withCString { userPtr in
                        cb(&out, urlPtr, userPtr, allowed, payload)
                    }
                }
                return cb(&out, urlPtr, nil, allowed, payload)
            }
        }
        return (rc, out)
    }

    @Test("provider receives URL, username, and allowed kinds")
    func providerInputs() async throws {
        nonisolated(unsafe) var seen: (URL, String?, CredentialKind)?
        let (rc, cred) = acquire(
            url: "https://github.com/owner/repo.git",
            usernameFromURL: "git",
            provider: { url, user, allowed in
                seen = (url, user, allowed)
                return .token("xyz")
            })
        defer { if let cred { git_credential_free(cred) } }

        #expect(rc == 0)
        #expect(cred != nil)
        let observed = try #require(seen)
        #expect(observed.0.absoluteString == "https://github.com/owner/repo.git")
        #expect(observed.1 == "git")
        #expect(observed.2.contains(.userPassword))
        #expect(observed.2.contains(.sshKey))
    }

    @Test("token() builds a userpass credential with x-access-token")
    func tokenCredential() async throws {
        let (rc, cred) = acquire(
            url: "https://github.com/x/y.git",
            provider: { _, _, _ in .token("ghp_abc") })
        defer { if let cred { git_credential_free(cred) } }
        #expect(rc == 0)
        #expect(cred != nil)
    }

    @Test("userPassword builds a credential")
    func userPasswordCredential() async throws {
        let (rc, cred) = acquire(
            url: "https://example.com/x.git",
            provider: { _, _, _ in .userPassword(username: "alice", password: "s3cret") })
        defer { if let cred { git_credential_free(cred) } }
        #expect(rc == 0)
        #expect(cred != nil)
    }

    @Test("username builds a credential")
    func usernameCredential() async throws {
        let (rc, cred) = acquire(
            url: "ssh://git@example.com/x.git",
            allowed: UInt32(GIT_CREDENTIAL_USERNAME.rawValue),
            provider: { _, _, _ in .username("git") })
        defer { if let cred { git_credential_free(cred) } }
        #expect(rc == 0)
        #expect(cred != nil)
    }

    @Test("default builds a credential")
    func defaultCredential() async throws {
        let (rc, cred) = acquire(
            url: "https://example.com/x.git",
            allowed: UInt32(GIT_CREDENTIAL_DEFAULT.rawValue),
            provider: { _, _, _ in .default })
        defer { if let cred { git_credential_free(cred) } }
        #expect(rc == 0)
        #expect(cred != nil)
    }

    @Test("provider returning nil yields GIT_PASSTHROUGH")
    func providerNilPassesThrough() async throws {
        let (rc, cred) = acquire(
            url: "https://example.com/x.git",
            provider: { _, _, _ in nil })
        defer { if let cred { git_credential_free(cred) } }
        #expect(rc == -30) // GIT_PASSTHROUGH
        #expect(cred == nil)
    }

    @Test("CredentialProviders.token convenience filters non-userPassword challenges")
    func tokenConvenienceFiltering() async throws {
        let provider: CredentialProvider = CredentialProviders.token("ghp_abc")

        // Userpass-allowed → returns a token.
        let (rc1, cred1) = acquire(
            url: "https://example.com/x.git",
            allowed: UInt32(GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue),
            provider: provider)
        defer { if let cred1 { git_credential_free(cred1) } }
        #expect(rc1 == 0)
        #expect(cred1 != nil)

        // SSH-only → no userpass allowed → provider returns nil → passthrough.
        let (rc2, cred2) = acquire(
            url: "ssh://git@example.com/x.git",
            allowed: UInt32(GIT_CREDENTIAL_SSH_KEY.rawValue),
            provider: provider)
        defer { if let cred2 { git_credential_free(cred2) } }
        #expect(rc2 == -30)
        #expect(cred2 == nil)
    }
}
