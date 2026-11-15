import Foundation
import NIOSSH
import Testing
@testable import SSHKit

@Suite("OpenSSH key material and serialization")
struct SSHKeyMaterialTests {
    @Test(arguments: ["id_ed25519_test", "id_ecdsa_test", "id_ecdsa384_test", "id_ecdsa521_test"])
    func keyMaterial(_ fixture: String) async throws {
        let key = try await IdentityLoader.loadKey(path: SSHKitFixtures.path(fixture))
        let line = try SSHKitFixtures.contents(fixture + ".pub").trimmingCharacters(in: .newlines)
        #expect(key.publicKey.openSSHLine(comment: key.comment) == line)
        #expect(try NIOSSHPublicKey(openSSHPublicKey: key.publicKey.openSSHLine()) == key.nioKey.publicKey)
        let data = Data("arbitrary signing data".utf8)
        #expect(try key.publicKey.isValidSignature(key.signatureBlob(for: data), for: data))
        #expect(try !key.publicKey.isValidSignature(key.signatureBlob(for: data), for: Data()))
    }

    @Test(arguments: ["ed25519", "ecdsa256", "ecdsa384", "ecdsa521"])
    func serialization(_ type: String) throws {
        let bits = Int(type.dropFirst(5)) ?? 256
        let key = try SSHPrivateKey.generate(type: type == "ed25519" ? type : "ecdsa", bits: bits, comment: "test")
        for passphrase in ["", "correct horse battery staple"] {
            let text = try key.openSSHFile(passphrase: passphrase)
            let parsed = try OpenSSHPrivateKeyFile.parse(text, path: "key", passphrase: passphrase)
            #expect(parsed.publicKey == key.publicKey)
            #expect(parsed.comment == "test")
            if !passphrase.isEmpty {
                #expect(throws: SSHIdentityDecryptionError.self) {
                    try OpenSSHPrivateKeyFile.parse(text, path: "key", passphrase: "wrong")
                }
            }
        }
    }
}
