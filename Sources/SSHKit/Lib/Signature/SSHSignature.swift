import Crypto
import Foundation

/// Detached SSHSIG version 1 (`PROTOCOL.sshsig`, `sshsig.c`).
public struct SSHSignature: Sendable {
    public let publicKey: SSHPublicKey
    public let namespace: String
    let hashAlgorithm: String
    let signature: [UInt8]

    public init(armored: String) throws {
        var reader = SSHWireReader(Array(try SSHArmor.decode(armored, label: "SSH SIGNATURE")))
        guard try reader.readBytes(6) == Array("SSHSIG".utf8) else {
            throw SSHKeygenError("invalid format")
        }
        let version = try reader.readUInt32()
        guard version <= 1 else {
            throw SSHKeygenError("Signature version \(version) is larger than supported version 1")
        }
        publicKey = try SSHPublicKey(blob: Data(reader.readString()))
        namespace = try reader.readUTF8String()
        _ = try reader.readString() // OpenSSH ignores reserved bytes.
        hashAlgorithm = try reader.readUTF8String()
        signature = try reader.readString()
        guard reader.isAtEnd else { throw SSHKeygenError("Signature contains trailing data") }
    }

    public init(signing message: Data, namespace: String, key: SSHPrivateKey) throws {
        publicKey = key.publicKey
        self.namespace = namespace
        hashAlgorithm = "sha512"
        signature = try key.signatureBlob(for: Self.signedData(message, namespace: namespace, hash: "sha512"))
    }

    public var armored: String {
        var writer = SSHWireWriter(bytes: Array("SSHSIG".utf8))
        writer.uint32(1)
        writer.string(publicKey.blob)
        writer.string(namespace)
        writer.string("")
        writer.string(hashAlgorithm)
        writer.string(signature)
        return SSHArmor.encode(Data(writer.bytes), label: "SSH SIGNATURE")
    }

    public func verify(message: Data, namespace expected: String) throws {
        guard namespace == expected else {
            throw SSHKeygenError("Couldn't verify signature: namespace does not match")
        }
        guard try publicKey.isValidSignature(
            signature, for: Self.signedData(message, namespace: expected, hash: hashAlgorithm)) else {
            throw SSHKeygenError("Signature verification failed: incorrect signature")
        }
    }

    private static func signedData(_ message: Data, namespace: String, hash: String) throws -> Data {
        let digest: Data
        switch hash {
        case "sha512": digest = Data(SHA512.hash(data: message))
        case "sha256": digest = Data(SHA256.hash(data: message))
        default: throw SSHKeygenError("sshsig_check_hashalg: unsupported hash algorithm \"\(hash)\"")
        }
        var writer = SSHWireWriter(bytes: Array("SSHSIG".utf8))
        writer.string(namespace)
        writer.string("")
        writer.string(hash)
        writer.string(digest)
        return Data(writer.bytes)
    }
}
