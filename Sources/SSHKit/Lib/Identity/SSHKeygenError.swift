/// A diagnostic from the supported OpenSSH key and signature operations.
public struct SSHKeygenError: Error, CustomStringConvertible, Sendable {
    public let description: String

    public init(_ description: String) { self.description = description }
}
