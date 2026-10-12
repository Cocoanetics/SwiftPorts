import Foundation
import NIOSSH
import Testing

@testable import SSHKit

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
}
