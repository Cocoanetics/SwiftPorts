import _CryptoExtras
import Crypto
import Foundation

extension SSHPrivateKey {
    /// `sshkey_private_to_blob2`: bcrypt (16 rounds) and aes256-ctr when protected.
    public func openSSHFile(passphrase: String = "") throws -> String {
        var privatePart = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        privatePart.uint32(check)
        privatePart.uint32(check)
        privatePart.string(publicKey.algorithm)
        switch material {
        case .ed25519(let key):
            privatePart.string(key.publicKey.rawRepresentation)
            privatePart.string(key.rawRepresentation + key.publicKey.rawRepresentation)
        case .p256(let key):
            privatePart.string("nistp256")
            privatePart.string(key.publicKey.x963Representation)
            privatePart.mpint(key.rawRepresentation)
        case .p384(let key):
            privatePart.string("nistp384")
            privatePart.string(key.publicKey.x963Representation)
            privatePart.mpint(key.rawRepresentation)
        case .p521(let key):
            privatePart.string("nistp521")
            privatePart.string(key.publicKey.x963Representation)
            privatePart.mpint(key.rawRepresentation)
        }
        privatePart.string(comment)
        let blockSize = passphrase.isEmpty ? 8 : 16
        var pad: UInt8 = 1
        while privatePart.bytes.count % blockSize != 0 {
            privatePart.bytes.append(pad)
            pad += 1
        }

        var container = SSHWireWriter(bytes: Array("openssh-key-v1\0".utf8))
        container.string(passphrase.isEmpty ? "none" : "aes256-ctr")
        container.string(passphrase.isEmpty ? "none" : "bcrypt")
        var options = SSHWireWriter()
        var encrypted = Data(privatePart.bytes)
        if !passphrase.isEmpty {
            let salt = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
            options.string(salt)
            options.uint32(16)
            let derived = try BCryptPBKDF.derive(
                passphrase: Array(passphrase.utf8), salt: salt, rounds: 16, keyLength: 48)
            encrypted = try AES._CTR.encrypt(
                encrypted, using: SymmetricKey(data: derived.prefix(32)),
                nonce: AES._CTR.Nonce(nonceBytes: derived.suffix(16)))
        }
        container.string(options.bytes)
        container.uint32(1)
        container.string(publicKey.blob)
        container.string(encrypted)
        return SSHArmor.encode(Data(container.bytes), label: "OPENSSH PRIVATE KEY")
    }
}
