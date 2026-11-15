@preconcurrency import Crypto
import Foundation
import NIOSSH

/// The key material retained by OpenSSH's key-file loader, also adaptable to NIO transport.
public struct SSHPrivateKey: Sendable {
    enum Material: Sendable {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
    }

    let material: Material
    public var comment: String

    init(_ material: Material, comment: String = "") {
        self.material = material
        self.comment = comment
    }

    public init(openSSHFile text: String, passphrase: String = "") throws {
        self = try OpenSSHPrivateKeyFile.parse(text, path: "", passphrase: passphrase)
    }

    public static func generate(type: String, bits: Int = 256, comment: String = "") throws -> Self {
        switch (type, bits) {
        case ("ed25519", _): return Self(.ed25519(.init()), comment: comment)
        case ("ecdsa", 256): return Self(.p256(.init()), comment: comment)
        case ("ecdsa", 384): return Self(.p384(.init()), comment: comment)
        case ("ecdsa", 521): return Self(.p521(.init()), comment: comment)
        default: throw SSHKeygenError("Invalid key length")
        }
    }

    public var nioKey: NIOSSHPrivateKey {
        switch material {
        case .ed25519(let key): return NIOSSHPrivateKey(ed25519Key: key)
        case .p256(let key): return NIOSSHPrivateKey(p256Key: key)
        case .p384(let key): return NIOSSHPrivateKey(p384Key: key)
        case .p521(let key): return NIOSSHPrivateKey(p521Key: key)
        }
    }

    public var publicKey: SSHPublicKey {
        var writer = SSHWireWriter()
        switch material {
        case .ed25519(let key):
            writer.string("ssh-ed25519")
            writer.string(key.publicKey.rawRepresentation)
        case .p256(let key):
            writer.string("ecdsa-sha2-nistp256")
            writer.string("nistp256")
            writer.string(key.publicKey.x963Representation)
        case .p384(let key):
            writer.string("ecdsa-sha2-nistp384")
            writer.string("nistp384")
            writer.string(key.publicKey.x963Representation)
        case .p521(let key):
            writer.string("ecdsa-sha2-nistp521")
            writer.string("nistp521")
            writer.string(key.publicKey.x963Representation)
        }
        return SSHPublicKey(validatedBlob: Data(writer.bytes))
    }

    func signatureBlob(for data: Data) throws -> [UInt8] {
        var writer = SSHWireWriter()
        writer.string(publicKey.algorithm)
        switch material {
        case .ed25519(let key): writer.string(try key.signature(for: data))
        case .p256(let key): writer.string(Self.ecSignature(try key.signature(for: data).rawRepresentation))
        case .p384(let key): writer.string(Self.ecSignature(try key.signature(for: data).rawRepresentation))
        case .p521(let key): writer.string(Self.ecSignature(try key.signature(for: data).rawRepresentation))
        }
        return writer.bytes
    }

    private static func ecSignature(_ raw: Data) -> [UInt8] {
        var writer = SSHWireWriter()
        writer.mpint(raw.prefix(raw.count / 2))
        writer.mpint(raw.suffix(raw.count / 2))
        return writer.bytes
    }
}
