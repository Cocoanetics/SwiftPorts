#if os(macOS) || os(Linux)
/// A fixture step (such as `ssh-keygen`) failed.
public struct ThrowawaySSHDError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
#endif
