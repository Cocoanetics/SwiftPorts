import Foundation

/// Author / committer identity for commit-creating operations.
///
/// The core SDK's own value type — deliberately independent of any host
/// framework so the module stays a pure libgit2 wrapper. Hosts that have
/// their own signature type (e.g. ForgeKit's `GitSignature`) map at the
/// boundary; the two fields are all there is.
public struct Signature: Sendable, Equatable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}
