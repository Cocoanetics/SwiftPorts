import Foundation

/// An `ext-<priority>-<name> sha256:<oid>` line of a pointer: the OID of
/// the content before extension `name` transformed it
/// (git-lfs `lfs/pointer.go`, `PointerExtension`).
public struct PointerExtension: Sendable, Equatable {
    public var name: String
    public var priority: Int
    public var oid: String
    public var oidType: String

    /// `NewPointerExtension`.
    public init(name: String, priority: Int, oid: String) {
        self.name = name
        self.priority = priority
        self.oid = oid
        self.oidType = Pointer.oidType
    }
}
