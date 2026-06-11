import Foundation
import ShellKit

public enum GzipKitError: Error, LocalizedError, Sendable, Equatable {
    case compressionFailed(String)
    case decompressionFailed(String)
    case cannotInferOutputName(URL)

    // The URL payload is a resolved (host) location; fold it back
    // through `Shell.displayPath` so a path-mapped sandbox never
    // sees the embedder's host layout on stderr (identity without
    // a mapping — issue #66).
    public var errorDescription: String? {
        switch self {
        case .compressionFailed(let m):
            return "gzip: compression failed: \(m)"
        case .decompressionFailed(let m):
            return "gzip: decompression failed: \(m)"
        case .cannotInferOutputName(let u):
            return "gzip: cannot infer output name from '\(Shell.displayPath(for: u))' (no .gz/.tgz/.taz suffix)"
        }
    }
}
