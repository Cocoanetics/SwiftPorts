import Foundation
import Crypto

/// A Git LFS v1 pointer — what git stores in place of a large file
/// (git-lfs `lfs/pointer.go`, `Pointer`).
public struct Pointer: Sendable, Equatable {
    /// The spec URL the pointer was encoded with. ``encoded`` always writes
    /// ``latestVersion``, as git-lfs does.
    public var version: String
    /// The object's SHA-256, 64 lowercase hex digits.
    public var oid: String
    public var size: Int64
    public var oidType: String
    /// Ordered by priority.
    public var extensions: [PointerExtension]
    /// Whether the bytes it was decoded from are exactly ``encoded``.
    public var canonical: Bool

    /// `https://git-lfs.github.com/spec/v1`.
    public static let latestVersion = "https://git-lfs.github.com/spec/v1"

    /// The versions a pointer may name: the alpha, pre-release and public
    /// spec URLs.
    public static let v1Aliases = [
        "http://git-media.io/v/2",
        "https://hawser.github.com/spec/v1",
        latestVersion,
    ]

    /// `sha256`, the only OID type git-lfs accepts.
    public static let oidType = "sha256"

    /// Pointers are never this big; larger content is not a pointer
    /// (`BlobSizeCutoff`).
    public static let blobSizeCutoff = 1024

    /// The SHA-256 of no bytes (`fs.EmptyObjectSHA256`).
    public static let emptyObjectSHA256 = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()

    /// `NewPointer`: a canonical pointer of the latest version.
    public init(oid: String, size: Int64, extensions: [PointerExtension] = []) {
        self.version = Self.latestVersion
        self.oid = oid
        self.size = size
        self.oidType = Self.oidType
        self.extensions = extensions
        self.canonical = true
    }

    /// The pointer for the empty file (`EmptyPointer`).
    public static var empty: Pointer {
        Pointer(oid: emptyObjectSHA256, size: 0)
    }

    /// The pointer text git-lfs writes: nothing for an empty object,
    /// otherwise `version`, the extensions in order, `oid` and `size`, each
    /// on its own line.
    public var encoded: String {
        guard size != 0 else { return "" }
        var text = "version \(Self.latestVersion)\n"
        for ext in extensions {
            text += "ext-\(ext.priority)-\(ext.name) \(ext.oidType):\(ext.oid)\n"
        }
        text += "oid \(oidType):\(oid)\n"
        text += "size \(size)\n"
        return text
    }
}
