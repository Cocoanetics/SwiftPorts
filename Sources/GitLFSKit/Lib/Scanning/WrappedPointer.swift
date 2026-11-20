/// A decoded pointer together with its Git blob and path (`lfs.WrappedPointer`).
public struct WrappedPointer: Sendable, Equatable {
    public let pointer: Pointer
    /// The full Git blob OID, distinct from the LFS object's SHA-256.
    public let oid: String
    public let name: String
    public let sourceName: String
    /// The diff-index status letter, or empty for a tree/history entry.
    public let status: String

    public init(pointer: Pointer, oid: String, name: String, sourceName: String = "", status: String = "") {
        self.pointer = pointer
        self.oid = oid
        self.name = name
        self.sourceName = sourceName
        self.status = status
    }
}
