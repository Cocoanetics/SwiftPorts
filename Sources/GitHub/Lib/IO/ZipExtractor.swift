import Foundation
import Sandbox
import ZipKit

/// Thin SwiftGH-side facade over `ZipKit.Archive` for the two ZIP
/// operations gh needs: streaming `gh run view --log` output, and
/// extracting `gh run download --extract` archives.
///
/// All real archive logic lives in `ZipKit` (which sits next door in
/// the SwiftPorts directory). This module only translates SwiftGH's
/// preferred parameter shape (Data → stdout, Data → URL).
public enum ZipExtractor {
    /// Walk every regular-file entry in `zipData` (sorted by path)
    /// and write its bytes to stdout, prefixed with a
    /// `=== <path> ===` header. Used by `gh run view --log`.
    public static func printConcatenatedTextEntries(zipData: Data) async throws {
        try await Archive.streamEntries(
            from: zipData,
            to: Stdio.stdout,
            printHeaders: true)
    }

    /// Extract every entry in `zipData` into `destination` (created if
    /// missing). Available for callers that want a directory of files
    /// rather than concatenated stdout output — e.g. a future
    /// `gh run download --extract`.
    public static func extract(
        zipData: Data, into destination: URL
    ) async throws {
        try await Archive.extract(
            from: zipData,
            options: ExtractOptions(destination: destination))
    }
}
