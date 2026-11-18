import Foundation

/// Why the local store refused an object, worded as git-lfs words it
/// (`fs/fs.go`, `tq/basic_download.go`, `tools/filetools.go`).
public enum LocalStoreError: Error, Sendable, Equatable, CustomStringConvertible {
    case tooShortObjectID(String)
    /// The object directory couldn't be made.
    case cannotCreateStorageDirectory(String, String)
    /// The file's SHA-256 isn't the OID it was to be stored as.
    case unexpectedOID(expected: String, actual: String, written: Int64)
    case cannotSetFileMode(String, String)
    /// Renaming the file into `objects/` failed: destination, source, why.
    case cannotReplace(String, String, String)

    public var description: String {
        switch self {
        case .tooShortObjectID(let oid):
            return "too short object ID: \(oid.goQuoted)"
        case .cannotCreateStorageDirectory(let directory, let reason):
            return "error trying to create local storage directory in \(directory.goQuoted): \(reason)"
        case .unexpectedOID(let expected, let actual, let written):
            return "expected OID \(expected), got \(actual) after \(written) bytes written"
        case .cannotSetFileMode(let file, let reason):
            return "can't set filemode on file \(file.goQuoted): \(reason)"
        case .cannotReplace(let destination, let source, let reason):
            return "cannot replace \(destination.goQuoted) with \(source.goQuoted): \(reason)"
        }
    }
}
