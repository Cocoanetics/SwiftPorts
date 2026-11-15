import Crypto
import Foundation
import Testing
@testable import SSHKit

@Suite("OpenSSH SSHSIG and allowed_signers")
struct SSHSignatureTests {
    private let message = Data("SwiftPorts SSHSIG fixture\n".utf8)

    @Test(arguments: ["id_ed25519_test", "id_ecdsa_test", "id_ecdsa384_test", "id_ecdsa521_test"])
    func upstreamFixtures(_ name: String) async throws {
        let signature = try SSHSignature(armored: SSHKitFixtures.contents(name + ".sig"))
        try signature.verify(message: message, namespace: "git")
        #expect(throws: SSHKeygenError.self) { try signature.verify(message: Data(), namespace: "git") }
        #expect(throws: SSHKeygenError.self) { try signature.verify(message: message, namespace: "other") }
        let key = try await IdentityLoader.loadKey(path: SSHKitFixtures.path(name))
        let ours = try SSHSignature(signing: message, namespace: "git", key: key)
        try SSHSignature(armored: ours.armored).verify(message: message, namespace: "git")
        // CryptoKit may randomize Ed25519 signing; BoringSSL is deterministic.
        #if !canImport(CryptoKit)
        if name == "id_ed25519_test" { #expect(ours.armored == signature.armored) }
        #endif
    }

    @Test func malformedSignatures() throws {
        let fixture = try SSHKitFixtures.contents("id_ed25519_test.sig")
        let bytes = try SSHArmor.decode(fixture, label: "SSH SIGNATURE")
        for size in [0, 5, 10, bytes.count - 1] {
            #expect(throws: (any Error).self) {
                try SSHSignature(armored: SSHArmor.encode(bytes.prefix(size), label: "SSH SIGNATURE"))
            }
        }
        var bad = bytes
        bad[0] ^= 1
        #expect(throws: (any Error).self) { try SSHSignature(armored: SSHArmor.encode(bad, label: "SSH SIGNATURE")) }
        bad = bytes
        bad[9] = 2
        #expect(throws: (any Error).self) { try SSHSignature(armored: SSHArmor.encode(bad, label: "SSH SIGNATURE")) }
        #expect(throws: (any Error).self) {
            try SSHSignature(armored: SSHArmor.encode(bytes + [0], label: "SSH SIGNATURE"))
        }
    }

    @Test func sha256AndAlgorithmMismatch() async throws {
        let key = try await IdentityLoader.loadKey(path: SSHKitFixtures.path("id_ed25519_test"))
        var signed = SSHWireWriter(bytes: Array("SSHSIG".utf8))
        signed.string("git")
        signed.string("")
        signed.string("sha256")
        signed.string(Data(SHA256.hash(data: message)))
        var blob = SSHWireWriter(bytes: Array("SSHSIG".utf8))
        blob.uint32(1)
        blob.string(key.publicKey.blob)
        blob.string("git")
        blob.string("")
        blob.string("sha256")
        blob.string(try key.signatureBlob(for: Data(signed.bytes)))
        try SSHSignature(armored: SSHArmor.encode(Data(blob.bytes), label: "SSH SIGNATURE"))
            .verify(message: message, namespace: "git")
        var signature = SSHWireWriter()
        signature.string("ecdsa-sha2-nistp256")
        signature.string([UInt8](repeating: 0, count: 64))
        #expect(try !key.publicKey.isValidSignature(signature.bytes, for: message))
    }

    @Test func allowedSigners() async throws {
        let key = try await IdentityLoader.loadKey(path: SSHKitFixtures.path("id_ed25519_test")).publicKey
        let line = "*@example.com,!mallory@example.com namespaces=\"git,file\","
            + "valid-after=\"20260101000000Z\",valid-before=\"20260102000000Z\" " + key.openSSHLine()
        let allowed = AllowedSigners("# comment\n\n" + line, path: "allowed")
        #expect(allowed.diagnostics.isEmpty)
        let start = try SSHKeygenTime.parse("20260101000000Z")
        let end = try SSHKeygenTime.parse("20260102000000Z")
        for time in [start, start.addingTimeInterval(1), end.addingTimeInterval(-1), end] {
            #expect(!allowed.principals(for: key, principal: "alice@example.com", namespace: "git", at: time).isEmpty)
        }
        for time in [start.addingTimeInterval(-1), end.addingTimeInterval(1)] {
            #expect(allowed.principals(for: key, at: time).isEmpty)
        }
        #expect(allowed.principals(for: key, principal: "mallory@example.com", at: start).isEmpty)
        #expect(allowed.principals(for: key, namespace: "other", at: start).isEmpty)
        #expect(allowed.principals(for: key, at: start) == ["*@example.com", "!mallory@example.com"])
        let ca = AllowedSigners("alice cert-authority " + key.openSSHLine(), path: "allowed")
        #expect(ca.diagnostics == ["allowed:1: cert-authority is unsupported"])
        #expect(ca.principals(for: key).isEmpty)
    }

    @Test func revocations() async throws {
        let key = try await IdentityLoader.loadKey(path: SSHKitFixtures.path("id_ed25519_test")).publicKey
        try SSHRevocationList.check(key, data: Data("# no revocations\n".utf8))
        #expect(throws: SSHKeygenError.self) { try SSHRevocationList.check(key, data: Data(key.openSSHLine().utf8)) }
        #expect(throws: SSHKeygenError.self) { try SSHRevocationList.check(key, data: Data("SSHKRL\n\0".utf8)) }
    }

    @Test(arguments: ["20260101", "202601010000", "20260101000000", "20260101000000Z"])
    func timeSyntax(_ text: String) throws { _ = try SSHKeygenTime.parse(text) }

    @Test(arguments: ["", "20260230", "2026010100", "20261301", "20260101006100Z"])
    func invalidTime(_ text: String) { #expect(throws: SSHKeygenError.self) { try SSHKeygenTime.parse(text) } }
}
