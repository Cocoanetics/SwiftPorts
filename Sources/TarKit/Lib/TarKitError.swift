import Foundation
import ShellKit

public enum TarKitError: Error, LocalizedError, Sendable, Equatable {
    case archiveOpenFailed(String)
    case writeFailed(URL, underlying: String)
    case readFailed(URL, underlying: String)
    /// Archive entry contains a path that would escape the destination
    /// (absolute, drive-letter, or `..`-traversing). Refusing to extract
    /// is the only safe response for untrusted tarballs.
    case unsafeEntryPath(String)

    // URL payloads are resolved (host) locations; the rendered message
    // folds them back through `Shell.displayPath` so a path-mapped
    // sandbox never sees the embedder's host layout on stderr
    // (identity without a mapping — issue #66).
    public var errorDescription: String? {
        switch self {
        case .archiveOpenFailed(let path):
            return "tar: cannot open archive '\(path)'"
        case .writeFailed(let url, let underlying):
            return "tar: cannot write '\(Shell.displayPath(for: url))': \(underlying)"
        case .readFailed(let url, let underlying):
            return "tar: cannot read '\(Shell.displayPath(for: url))': \(underlying)"
        case .unsafeEntryPath(let path):
            return "tar: refusing to extract unsafe entry path '\(path)'"
        }
    }
}
