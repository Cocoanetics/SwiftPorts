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

    /// Visit a blob without materialising it when its ODB backend supports
    /// streaming reads. Packed backends fall back to one libgit2 read while
    /// still presenting bounded chunks to the consumer.
    @_spi(GitLFSKit)
    public func forEachBlobChunk(
        ofOID oid: String,
        _ consume: (UnsafeRawBufferPointer) throws -> Void
    ) async throws {
        let chunkSize = 64 * 1024
        try await withRepository { repository in
            guard let repo = Self.handle(of: repository) else {
                throw Libgit2Error(
                    code: -1, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                    message: "cannot reach GitKit's repository handle to stream a blob")
            }
            var id = git_oid()
            try Self.check(oid.withCString { git_oid_fromstr(&id, $0) })
            var odb: OpaquePointer?
            try Self.check(git_repository_odb(&odb, repo))
            defer { git_odb_free(odb) }

            var stream: UnsafeMutablePointer<git_odb_stream>?
            var size = 0
            var kind = GIT_OBJECT_INVALID
            let opened = git_odb_open_rstream(&stream, &size, &kind, odb, &id)
            guard opened == 0, let stream else {
                // libgit2's packed backend has no read-stream implementation.
                let data = try repository.catFileBlob(oid)
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = min(chunkSize, bytes.count - offset)
                        try consume(UnsafeRawBufferPointer(rebasing: bytes[offset ..< offset + count]))
                        offset += count
                    }
                }
                return
            }
            defer { git_odb_stream_free(stream) }
            guard kind == GIT_OBJECT_BLOB else {
                throw Libgit2Error(code: -1, klass: Int32(GIT_ERROR_OBJECT.rawValue),
                                   message: "object is not a blob")
            }

            var buffer = [UInt8](repeating: 0, count: chunkSize)
            var remaining = size
            while remaining > 0 {
                let capacity = min(buffer.count, remaining)
                let read = buffer.withUnsafeMutableBytes { bytes in
                    git_odb_stream_read(stream, bytes.baseAddress?.assumingMemoryBound(to: CChar.self), capacity)
                }
                try Self.check(read)
                guard read > 0 else {
                    throw Libgit2Error(code: -1, klass: Int32(GIT_ERROR_ODB.rawValue),
                                       message: "blob stream ended before its declared size")
                }
                try buffer.withUnsafeBytes {
                    try consume(UnsafeRawBufferPointer(rebasing: $0[..<Int(read)]))
                }
                remaining -= Int(read)
            }
        }
    }
}
