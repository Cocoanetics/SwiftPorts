import Foundation

/// Why bytes didn't decode as a pointer, worded as git-lfs words it
/// (`lfs/pointer.go`, `errors/types.go`).
public enum PointerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No `git-media`, `hawser` or `git-lfs` anywhere in the data.
    case invalidHeader
    /// A line without a space.
    case errorReadingLine(Int, String)
    /// A line after `size`.
    case extraLine(String)
    /// A key other than the one due, and not an extension.
    case badPointerKey(expected: String, actual: String)
    case missingVersion
    case invalidVersion(String)
    case missingOID
    case invalidOIDValue(String)
    case invalidOIDType(String)
    case invalidOID(String)
    case invalidSize(String)
    case invalidExtensionValue(String)
    case invalidPriority(String)
    case duplicatePriority(Int)
    /// A file at least ``Pointer/blobSizeCutoff`` bytes long.
    case fileSizeExceedsCutoff
    case notARegularFile(String)

    /// Whether git-lfs takes the data for something other than a pointer
    /// (`errors.IsNotAPointerError`), rather than a broken one.
    public var isNotAPointer: Bool {
        switch self {
        case .invalidHeader, .errorReadingLine, .extraLine, .missingVersion, .fileSizeExceedsCutoff:
            return true
        case .badPointerKey(let expected, _):
            return expected == "version"
        default:
            return false
        }
    }

    public var description: String {
        isNotAPointer ? "Pointer file error: \(message)" : message
    }

    private var message: String {
        switch self {
        case .invalidHeader: return "invalid header"
        case .errorReadingLine(let line, let text): return "error reading line \(line): \(text)"
        case .extraLine(let text): return "extra line: \(text)"
        case .badPointerKey(let expected, let actual): return "pointer parsing: Expected key \(expected), got \(actual)"
        case .missingVersion: return "Missing version"
        case .invalidVersion(let version): return "Invalid version: \(version)"
        case .missingOID: return "Invalid OID"
        case .invalidOIDValue(let value): return "Invalid OID value: \(value)"
        case .invalidOIDType(let type): return "Invalid OID type: \(type)"
        case .invalidOID(let oid): return "Invalid OID: \(oid)"
        case .invalidSize(let value): return "invalid size: \(value.goQuoted)"
        case .invalidExtensionValue(let value): return "Invalid extension value: \(value)"
        case .invalidPriority(let priority): return "Invalid priority: \(priority)"
        case .duplicatePriority(let priority): return "duplicate priority found: \(priority)"
        case .fileSizeExceedsCutoff: return "file size exceeds Git LFS pointer size cutoff"
        case .notARegularFile(let path): return "not a regular file: \(path.goQuoted)"
        }
    }
}
