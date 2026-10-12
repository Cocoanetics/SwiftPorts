import _CryptoExtras
import Crypto
import Foundation
import NIOSSH

/// Parses the `openssh-key-v1` private-key container (`PROTOCOL.key`). Only ed25519 and ECDSA
/// (P-256/384/521) keys are supported, matching `NIOSSHPrivateKey`'s backing-key set (no RSA —
/// confirmed against `swift-nio-ssh` at the pinned commit, see Docs/SSH.md). Encrypted containers
/// are supported for `kdfname "bcrypt"` with cipher `aes256-ctr` or `aes256-gcm@openssh.com` —
/// `ssh-keygen`'s own new-format default and its AEAD alternative (issue #115); every other
/// cipher/KDF combination is out of scope.
enum OpenSSHPrivateKeyFile {
    private static let magic: [UInt8] = Array("openssh-key-v1\0".utf8)

    static func parse(_ pemText: String, path: String, passphrase: String) throws -> NIOSSHPrivateKey {
        guard let base64Body = Self.extractBase64Body(from: pemText) else {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "not an OPENSSH PRIVATE KEY file")
        }
        guard let containerBytes = Data(base64Encoded: base64Body) else {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "invalid base64 in key file")
        }

        var reader = SSHWireReader(Array(containerBytes))
        guard try reader.readBytes(Self.magic.count) == Self.magic else {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "not an openssh-key-v1 container")
        }

        let cipherName = try reader.readUTF8String()
        let kdfName = try reader.readUTF8String()
        let kdfOptions = try reader.readString()

        guard try reader.readUInt32() == 1 else {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "multi-key files are not supported")
        }
        _ = try reader.readString()  // public key (redundant — recomputed from the private section)

        // Read the "encrypted, padded list of private keys" field's length manually (rather than
        // as a wire string via `readString()`) so a trailing AEAD tag — appended after it, outside
        // its own declared length — can still be read from the same cursor (`sshkey.c`'s
        // `private2_decrypt`: `encrypted_len` uint32, then that many ciphertext bytes, then
        // `cipher_authlen(cipher)` tag bytes).
        let encryptedLength = Int(try reader.readUInt32())
        let ciphertext = try reader.readBytes(encryptedLength)

        let privateBytes: [UInt8]
        if cipherName == "none" {
            guard kdfName == "none" else {
                throw SSHError.unsupportedKeyFormat(path: path, reason: "unsupported kdf \(kdfName) for cipher none")
            }
            privateBytes = ciphertext
        } else {
            privateBytes = try Self.decrypt(
                ciphertext: ciphertext,
                reader: &reader,
                cipherName: cipherName,
                kdfName: kdfName,
                kdfOptions: kdfOptions,
                passphrase: passphrase,
                path: path)
        }

        var privateReader = SSHWireReader(privateBytes)
        let checkint1 = try privateReader.readUInt32()
        let checkint2 = try privateReader.readUInt32()
        guard checkint1 == checkint2 else {
            // For an encrypted key, a checkint mismatch means the decrypted bytes are garbage —
            // i.e. the wrong passphrase (`PROTOCOL.key` §3: the whole point of the duplicated
            // checkint is a quick decryption-succeeded check). For `cipher none` there is no
            // passphrase to blame; the file itself is corrupt.
            if cipherName == "none" {
                throw SSHError.unsupportedKeyFormat(path: path, reason: "corrupt private key (checkint mismatch)")
            }
            throw SSHIdentityDecryptionError.wrongPassphrase(path: path)
        }

        let keyType = try privateReader.readUTF8String()
        return try Self.privateKey(ofType: keyType, from: &privateReader, path: path)
    }

    /// Derives the cipher key + IV via `BCryptPBKDF` and decrypts the private-key ciphertext,
    /// mirroring `private2_decrypt()` in `sshkey.c`.
    private static func decrypt(
        ciphertext: [UInt8],
        reader: inout SSHWireReader,
        cipherName: String,
        kdfName: String,
        kdfOptions: [UInt8],
        passphrase: String,
        path: String
    ) throws -> [UInt8] {
        guard kdfName == "bcrypt" else {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "unsupported kdf \(kdfName) (only bcrypt is implemented)")
        }
        guard let parameters = Self.cipherParameters(cipherName) else {
            throw SSHError.unsupportedKeyFormat(
                path: path,
                reason: "unsupported cipher \(cipherName) (only aes256-ctr and aes256-gcm@openssh.com are implemented)")
        }
        guard !passphrase.isEmpty else {
            throw SSHIdentityDecryptionError.declined(path: path)
        }

        var kdfReader = SSHWireReader(kdfOptions)
        let salt = try kdfReader.readString()
        let rounds = try kdfReader.readUInt32()

        let keyMaterial: [UInt8]
        do {
            keyMaterial = try BCryptPBKDF.derive(
                passphrase: Array(passphrase.utf8),
                salt: salt,
                rounds: Int(rounds),
                keyLength: parameters.keyLength + parameters.ivLength)
        } catch {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "invalid bcrypt KDF options")
        }
        let key = Array(keyMaterial.prefix(parameters.keyLength))
        let iv = Array(keyMaterial.suffix(parameters.ivLength))
        let authTag = parameters.authLength > 0 ? try reader.readBytes(parameters.authLength) : []

        do {
            if parameters.authLength > 0 {
                // aes256-gcm@openssh.com: no additional authenticated data, matching
                // `private2_decrypt`'s `cipher_crypt(..., aadlen: 0, authlen)`.
                let sealedBox = try AES.GCM.SealedBox(
                    nonce: AES.GCM.Nonce(data: iv),
                    ciphertext: Data(ciphertext),
                    tag: Data(authTag))
                return Array(try AES.GCM.open(sealedBox, using: SymmetricKey(data: key)))
            } else {
                // aes256-ctr: a plain keystream XOR, no integrity check of its own — the checkint
                // comparison in `parse(_:path:passphrase:)` is what catches a wrong passphrase.
                let plaintext = try AES._CTR.decrypt(
                    Data(ciphertext),
                    using: SymmetricKey(data: key),
                    nonce: AES._CTR.Nonce(nonceBytes: iv))
                return Array(plaintext)
            }
        } catch {
            // A GCM tag mismatch throws here. `sshkey.c`'s equivalent (`SSH_ERR_MAC_INVALID`) is
            // remapped to `SSH_ERR_KEY_WRONG_PASSPHRASE` the same way.
            throw SSHIdentityDecryptionError.wrongPassphrase(path: path)
        }
    }

    /// `(key_len, iv_len, auth_len)` from `cipher.c`'s `ciphers[]` table — `iv_len` defaults to
    /// `block_size` (16) when the table's own field is 0.
    private static func cipherParameters(_ name: String) -> (keyLength: Int, ivLength: Int, authLength: Int)? {
        switch name {
        case "aes256-ctr":
            return (keyLength: 32, ivLength: 16, authLength: 0)
        case "aes256-gcm@openssh.com":
            return (keyLength: 32, ivLength: 12, authLength: 16)
        default:
            return nil
        }
    }

    /// Per-key-type private blob layout, "encoded using the same rules as used for SSH agent"
    /// (`PROTOCOL.key` §3) — the exact byte layout `ssh_ed25519_serialize_private()`
    /// (`ssh-ed25519.c` lines 67-78) and `ssh_ecdsa_serialize_private()` (`ssh-ecdsa.c` lines
    /// 145-159) write.
    private static func privateKey(
        ofType keyType: String,
        from reader: inout SSHWireReader,
        path: String
    ) throws -> NIOSSHPrivateKey {
        switch keyType {
        case "ssh-ed25519":
            _ = try reader.readString()  // public key (32 bytes, redundant)
            let secretAndPublic = try reader.readString()  // 64 bytes: 32-byte seed + 32-byte public key
            guard secretAndPublic.count == 64 else {
                throw SSHError.unsupportedKeyFormat(path: path, reason: "malformed ed25519 private key")
            }
            let seed = Array(secretAndPublic.prefix(32))
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: seed))

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curveName = try reader.readUTF8String()
            _ = try reader.readString()  // public point Q (redundant)
            let scalar = try reader.readMPIntMagnitude()

            switch curveName {
            case "nistp256":
                return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: Self.leftPad(scalar, to: 32)))
            case "nistp384":
                return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: Self.leftPad(scalar, to: 48)))
            case "nistp521":
                return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: Self.leftPad(scalar, to: 66)))
            default:
                throw SSHError.unsupportedKeyFormat(path: path, reason: "unknown ECDSA curve \(curveName)")
            }

        default:
            throw SSHError.unsupportedKeyFormat(
                path: path,
                reason: "unsupported key type \(keyType) (only ed25519 and ECDSA are implemented)"
            )
        }
    }

    private static func leftPad(_ bytes: [UInt8], to length: Int) -> [UInt8] {
        guard bytes.count < length else {
            return Array(bytes.suffix(length))
        }
        return [UInt8](repeating: 0, count: length - bytes.count) + bytes
    }

    /// Extracts the base64 body between the `-----BEGIN/END OPENSSH PRIVATE KEY-----` PEM markers.
    private static func extractBase64Body(from pemText: String) -> String? {
        let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let endMarker = "-----END OPENSSH PRIVATE KEY-----"
        guard
            let beginRange = pemText.range(of: beginMarker),
            let endRange = pemText.range(of: endMarker),
            beginRange.upperBound <= endRange.lowerBound
        else {
            return nil
        }
        return pemText[beginRange.upperBound..<endRange.lowerBound]
            .components(separatedBy: .newlines)
            .joined()
    }
}
