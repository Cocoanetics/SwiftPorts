import Crypto
import Foundation

/// The public-key wire encoding used by OpenSSH key lines and SSHSIG signatures.
public struct SSHPublicKey: Sendable, Equatable {
    public let blob: Data
    public let algorithm: String

    init(validatedBlob: Data) {
        self.blob = validatedBlob
        var reader = SSHWireReader(Array(validatedBlob))
        self.algorithm = (try? reader.readUTF8String()) ?? ""
    }

    public init(blob: Data) throws {
        self.init(validatedBlob: blob)
        var reader = SSHWireReader(Array(blob))
        _ = try reader.readUTF8String()
        switch algorithm {
        case "ssh-ed25519":
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: reader.readString())
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            let curve = try reader.readUTF8String()
            guard algorithm == "ecdsa-sha2-" + curve else { throw SSHKeygenError("invalid format") }
            let point = try reader.readString()
            switch curve {
            case "nistp256": _ = try P256.Signing.PublicKey(x963Representation: point)
            case "nistp384": _ = try P384.Signing.PublicKey(x963Representation: point)
            default: _ = try P521.Signing.PublicKey(x963Representation: point)
            }
        default: throw SSHKeygenError("unsupported key type")
        }
        guard reader.isAtEnd else { throw SSHKeygenError("invalid format") }
    }

    public init(openSSHLine: String) throws {
        let fields = openSSHLine.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else {
            throw SSHKeygenError("invalid format")
        }
        try self.init(blob: blob)
        guard algorithm == fields[0] else { throw SSHKeygenError("invalid format") }
    }

    /// `sshkey_parse_pubkey_from_private_fileblob_type`: the public half needs no passphrase.
    public init(openSSHPrivateKeyFile text: String) throws {
        let data = try SSHArmor.decode(text, label: "OPENSSH PRIVATE KEY")
        var reader = SSHWireReader(Array(data))
        guard try reader.readBytes(15) == Array("openssh-key-v1\0".utf8) else {
            throw SSHKeygenError("invalid format")
        }
        _ = try reader.readString()
        _ = try reader.readString()
        _ = try reader.readString()
        guard try reader.readUInt32() == 1 else { throw SSHKeygenError("invalid format") }
        try self.init(blob: Data(reader.readString()))
    }

    public func openSSHLine(comment: String = "") -> String {
        algorithm + " " + blob.base64EncodedString() + (comment.isEmpty ? "" : " " + comment)
    }

    public var sha256Fingerprint: String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public var bits: Int {
        switch algorithm {
        case "ecdsa-sha2-nistp384": return 384
        case "ecdsa-sha2-nistp521": return 521
        default: return 256
        }
    }

    public var shortTypeName: String { algorithm == "ssh-ed25519" ? "ED25519" : "ECDSA" }

    func isValidSignature(_ signature: [UInt8], for data: Data) throws -> Bool {
        var sig = SSHWireReader(signature)
        guard try sig.readUTF8String() == algorithm else { return false }
        let encoded = try sig.readString()
        guard sig.isAtEnd else { return false }
        var key = SSHWireReader(Array(blob))
        _ = try key.readString()
        if algorithm == "ssh-ed25519" {
            return try Curve25519.Signing.PublicKey(rawRepresentation: key.readString())
                .isValidSignature(encoded, for: data)
        }
        _ = try key.readString()
        let point = try key.readString()
        var integers = SSHWireReader(encoded)
        let length = (bits + 7) / 8
        let r = try integers.readMPIntMagnitude(), s = try integers.readMPIntMagnitude()
        guard integers.isAtEnd, r.count <= length, s.count <= length else { return false }
        let raw = Data([UInt8](repeating: 0, count: length - r.count) + r
                       + [UInt8](repeating: 0, count: length - s.count) + s)
        switch bits {
        case 256:
            return try P256.Signing.PublicKey(x963Representation: point)
                .isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: raw), for: data)
        case 384:
            return try P384.Signing.PublicKey(x963Representation: point)
                .isValidSignature(P384.Signing.ECDSASignature(rawRepresentation: raw), for: data)
        default:
            return try P521.Signing.PublicKey(x963Representation: point)
                .isValidSignature(P521.Signing.ECDSASignature(rawRepresentation: raw), for: data)
        }
    }
}
