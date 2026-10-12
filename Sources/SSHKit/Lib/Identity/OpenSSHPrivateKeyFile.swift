import Crypto
import Foundation
import NIOSSH

/// Parses the `openssh-key-v1` private-key container (`PROTOCOL.key`). Only unencrypted ed25519
/// and ECDSA (P-256/384/521) keys are supported, matching both `NIOSSHPrivateKey`'s backing-key
/// set (no RSA — confirmed against `swift-nio-ssh` at the pinned commit, see Docs/SSH.md) and this
/// port's Phase-1 scope (no passphrase decryption).
enum OpenSSHPrivateKeyFile {
    private static let magic: [UInt8] = Array("openssh-key-v1\0".utf8)

    static func parse(_ pemText: String, path: String) throws -> NIOSSHPrivateKey {
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
        _ = try reader.readString()  // kdfoptions
        guard cipherName == "none", kdfName == "none" else {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "encrypted private keys are not supported")
        }

        guard try reader.readUInt32() == 1 else {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "multi-key files are not supported")
        }
        _ = try reader.readString()  // public key (redundant — recomputed from the private section)

        var privateReader = SSHWireReader(try reader.readString())
        let checkint1 = try privateReader.readUInt32()
        let checkint2 = try privateReader.readUInt32()
        guard checkint1 == checkint2 else {
            throw SSHError.unsupportedKeyFormat(path: path, reason: "corrupt private key (checkint mismatch)")
        }

        let keyType = try privateReader.readUTF8String()
        return try Self.privateKey(ofType: keyType, from: &privateReader, path: path)
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
