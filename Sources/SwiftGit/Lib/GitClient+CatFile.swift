import Foundation
import CGitKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` cat-file operations
// (`GitKit/Repository+CatFile.swift`).
extension GitClient {

    /// Look up a single object's kind and size — `git cat-file -t -s`.
    public func objectMetadata(of revspec: String) async throws -> ObjectMetadata {
        try await withRepository { try $0.objectMetadata(of: revspec) }
    }

    /// Read only an object's database header and return its blob size.
    ///
    /// `oid` is a full object id already obtained from a tree, index or
    /// revision walk. Unlike a blob lookup, this does not inflate or allocate
    /// the payload, so callers can reject large blobs safely.
    public func blobSize(ofOID oid: String) async throws -> Int? {
        try await withRepository { repository in
            guard let repo = Self.handle(of: repository) else {
                throw Libgit2Error(
                    code: -1, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                    message: "cannot reach GitKit's repository handle to read an object header")
            }
            var id = git_oid()
            try Self.check(oid.withCString { git_oid_fromstr(&id, $0) })
            var odb: OpaquePointer?
            try Self.check(git_repository_odb(&odb, repo))
            defer { git_odb_free(odb) }
            var size = 0
            var kind = GIT_OBJECT_INVALID
            try Self.check(git_odb_read_header(&size, &kind, odb, &id))
            return kind == GIT_OBJECT_BLOB ? size : nil
        }
    }

    /// Read the raw bytes of a blob — `git cat-file -p` for blobs.
    public func catFileBlob(_ revspec: String) async throws -> Data {
        try await withRepository { try $0.catFileBlob(revspec) }
    }
}
