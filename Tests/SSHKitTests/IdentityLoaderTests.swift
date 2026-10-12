import Foundation
import NIOSSH
import Testing

@testable import SSHKit

/// Counts prompt invocations across a `@Sendable` `IdentityLoader.PassphrasePrompt` closure.
/// `IdentityLoader` only ever calls one prompt at a time, sequentially — this just sidesteps the
/// "mutation of captured var in concurrently-executing code" diagnostic that capturing a plain
/// `var` in an `@Sendable` closure would trigger.
private final class PromptCallCounter: @unchecked Sendable {
    private(set) var count = 0

    func increment() {
        self.count += 1
    }
}

@Suite("IdentityLoader")
struct IdentityLoaderTests {
    /// Parses a real `ssh-keygen`-generated private key and checks the derived public key matches
    /// the companion `.pub` file byte-for-byte — the strongest available proof this port's
    /// `openssh-key-v1` parser agrees with real OpenSSH.
    private func assertRoundTrips(_ baseName: String) async throws {
        let privateKey = try await IdentityLoader.load(path: SSHKitFixtures.path(baseName))
        let expectedPublicKeyLine = try SSHKitFixtures.contents("\(baseName).pub")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPublicKey = try NIOSSHPublicKey(openSSHPublicKey: expectedPublicKeyLine)
        #expect(privateKey.publicKey == expectedPublicKey)
    }

    @Test func ed25519RoundTrips() async throws {
        try await self.assertRoundTrips("id_ed25519_test")
    }

    @Test func ecdsaP256RoundTrips() async throws {
        try await self.assertRoundTrips("id_ecdsa_test")
    }

    @Test func ecdsaP384RoundTrips() async throws {
        try await self.assertRoundTrips("id_ecdsa384_test")
    }

    @Test func ecdsaP521RoundTrips() async throws {
        try await self.assertRoundTrips("id_ecdsa521_test")
    }

    @Test func missingIdentityFileThrows() async throws {
        await #expect(throws: SSHError.self) {
            try await IdentityLoader.load(path: "/nonexistent/id_ed25519_\(UUID().uuidString)")
        }
    }

    @Test func loadAvailableSkipsMissingDefaultCandidates() async throws {
        let keys = try await IdentityLoader.loadAvailable(paths: [
            "/nonexistent/id_rsa_\(UUID().uuidString)",
            SSHKitFixtures.path("id_ed25519_test"),
        ])
        #expect(keys.count == 1)
    }

    /// Real `ssh-keygen -o`-encrypted fixtures (`bcrypt` KDF) — see `Fixtures/` for how they were
    /// produced. Passphrase: "correct horse battery staple".
    private func assertEncryptedRoundTrips(_ baseName: String) async throws {
        let privateKey = try await IdentityLoader.load(
            path: SSHKitFixtures.path(baseName),
            passphrasePrompt: { _ in "correct horse battery staple" })
        let expectedPublicKeyLine = try SSHKitFixtures.contents("\(baseName).pub")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedPublicKey = try NIOSSHPublicKey(openSSHPublicKey: expectedPublicKeyLine)
        #expect(privateKey.publicKey == expectedPublicKey)
    }

    @Test func encryptedAES256CTRKeyRoundTrips() async throws {
        try await self.assertEncryptedRoundTrips("id_ed25519_enc_ctr_test")
    }

    @Test func encryptedAES256GCMKeyRoundTrips() async throws {
        try await self.assertEncryptedRoundTrips("id_ed25519_enc_gcm_test")
    }

    @Test func emptyPassphraseIsTriedBeforePrompting() async throws {
        // `load_identity_file` always tries "" first; an unencrypted key must never trigger a
        // prompt at all.
        let counter = PromptCallCounter()
        _ = try await IdentityLoader.load(
            path: SSHKitFixtures.path("id_ed25519_test"),
            passphrasePrompt: { _ in
                counter.increment()
                return "unused"
            })
        #expect(counter.count == 0)
    }

    @Test func wrongPassphraseRetriesThenGivesUp() async throws {
        let counter = PromptCallCounter()
        await #expect(throws: SSHIdentityDecryptionError.self) {
            try await IdentityLoader.load(
                path: SSHKitFixtures.path("id_ed25519_enc_ctr_test"),
                passphrasePrompt: { _ in
                    counter.increment()
                    return "definitely the wrong passphrase"
                })
        }
        // One empty-passphrase attempt, then up to 3 prompted retries (`NumberOfPasswordPrompts`).
        #expect(counter.count == 3)
    }

    @Test func emptyPromptResponseDeclinesImmediately() async throws {
        await #expect(throws: SSHIdentityDecryptionError.self) {
            try await IdentityLoader.load(
                path: SSHKitFixtures.path("id_ed25519_enc_ctr_test"),
                passphrasePrompt: { _ in "" })
        }
    }

    @Test func loadAvailableSkipsAnUndecryptableEncryptedIdentity() async throws {
        let keys = try await IdentityLoader.loadAvailable(
            paths: [
                SSHKitFixtures.path("id_ed25519_enc_ctr_test"),
                SSHKitFixtures.path("id_ed25519_test"),
            ],
            passphrasePrompt: { _ in "definitely the wrong passphrase" })
        #expect(keys.count == 1)
    }
}
