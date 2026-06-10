import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` cat-file operations
// (`GitKit/Repository+CatFile.swift`).
extension GitClient {

    /// Look up a single object's kind and size — `git cat-file -t -s`.
    public func objectMetadata(of revspec: String) async throws -> ObjectMetadata {
        try await withRepository { try $0.objectMetadata(of: revspec) }
    }

    /// Read the raw bytes of a blob — `git cat-file -p` for blobs.
    public func catFileBlob(_ revspec: String) async throws -> Data {
        try await withRepository { try $0.catFileBlob(revspec) }
    }
}
