import Foundation
import ShellKit

public enum ZipKitError: Error, LocalizedError, Sendable {
    case archiveOpenFailed(String)
    case crcMismatch(entry: String, expected: UInt32, actual: UInt32)
    case entryNotFound(String)
    case destinationExists(URL)
    case writeFailed(URL, underlying: String)
    /// Archive entry contains a path that would escape the destination
    /// (absolute, drive-letter, or `..`-traversing). Refusing to extract
    /// is the only safe response for untrusted archives.
    case unsafeEntryPath(String)

    public var errorDescription: String? {
        switch self {
        case .archiveOpenFailed(let reason):
            return "Couldn't open archive: \(reason)"
        case .crcMismatch(let entry, let expected, let actual):
            return "CRC mismatch on \(entry): expected \(String(expected, radix: 16)), got \(String(actual, radix: 16))"
        case .entryNotFound(let name):
            return "No such entry in archive: \(name)"
        // URL payloads are resolved (host) locations; fold them back
        // through `Shell.displayPath` so a path-mapped sandbox never
        // sees the embedder's host layout on stderr (identity without
        // a mapping — issue #66).
        case .destinationExists(let url):
            return "Destination already exists: \(Shell.displayPath(for: url)) (use --overwrite or --never-overwrite to choose)"
        case .writeFailed(let url, let underlying):
            return "Couldn't write \(Shell.displayPath(for: url)): \(underlying)"
        case .unsafeEntryPath(let path):
            return "Refusing to extract unsafe entry path: \(path)"
        }
    }
}
