import Foundation
import ShellKit

public enum Bzip2KitError: Error, LocalizedError, Sendable, Equatable {
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
            return "bzip2: compression failed: \(m)"
        case .decompressionFailed(let m):
            return "bzip2: decompression failed: \(m)"
        case .cannotInferOutputName(let u):
            return "bzip2: cannot infer output name from '\(Shell.displayPath(for: u))' (no .bz2/.tbz/.tbz2 suffix)"
        }
    }
}
