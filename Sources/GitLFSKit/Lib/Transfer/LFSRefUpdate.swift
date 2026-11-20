/// One proposed update of a remote ref, as a pre-push hook line gives it
/// (`<local ref> <local sha1> <remote ref> <remote sha1>`; `git.RefUpdate`).
public struct LFSRefUpdate: Sendable, Equatable {
    public var localRef: String
    public var localOID: String
    public var remoteRef: String
    public var remoteOID: String

    public init(localRef: String, localOID: String, remoteRef: String, remoteOID: String) {
        self.localRef = localRef
        self.localOID = localOID
        self.remoteRef = remoteRef
        self.remoteOID = remoteOID
    }

    /// `git.IsZeroObjectID`: a SHA-1 or SHA-256 length ID made only of `0` characters.
    static func isZero(_ oid: String) -> Bool {
        (oid.utf8.count == 40 || oid.utf8.count == 64) && oid.utf8.allSatisfy { $0 == UInt8(ascii: "0") }
    }
}
