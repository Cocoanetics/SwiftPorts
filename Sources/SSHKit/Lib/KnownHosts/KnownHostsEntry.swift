import NIOSSH

/// One parsed line from a `known_hosts` file: `host-field key-type base64-key [comment]`
/// (`hostfile.c`). `host-field` is either a comma-separated pattern list or a hashed
/// `|1|salt|hash` field (see `HostKeyHashing`).
public struct KnownHostsEntry: Sendable {
    public var hostField: String

    /// The wire algorithm identifier, e.g. `"ssh-ed25519"`, `"ecdsa-sha2-nistp256"`.
    public var algorithm: String

    public var publicKey: NIOSSHPublicKey
    public var comment: String?
    public var sourceDescription: String
    public var lineNumber: Int

    public init(
        hostField: String,
        algorithm: String,
        publicKey: NIOSSHPublicKey,
        comment: String?,
        sourceDescription: String,
        lineNumber: Int
    ) {
        self.hostField = hostField
        self.algorithm = algorithm
        self.publicKey = publicKey
        self.comment = comment
        self.sourceDescription = sourceDescription
        self.lineNumber = lineNumber
    }

    public func matches(host: String) -> Bool {
        if self.hostField.hasPrefix(HostKeyHashing.magic) {
            return HostKeyHashing.matches(host: host, hashedField: self.hostField)
        }
        return SSHPatternList.matches(host: host, tokens: self.hostField.split(separator: ","))
    }
}
