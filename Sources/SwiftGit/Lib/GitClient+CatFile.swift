import Foundation
import libgit2

/// Compact metadata about a git object — what `cat-file -t/-s/-e` reads.
public struct ObjectMetadata: Sendable {
    public enum Kind: String, Sendable {
        case blob, tree, commit, tag
    }
    public let sha: String
    public let kind: Kind
    /// Size of the object's serialized payload, in bytes.
    public let size: Int
}

extension GitClient {

    /// Look up a single object by ref or SHA. Returns its kind and size
    /// without materialising the payload — corresponds to
    /// `git cat-file -t -s`.
    public func objectMetadata(of revspec: String) async throws -> ObjectMetadata {
        try await withRepository { repo in
            var obj: OpaquePointer?
            try check(revspec.withCString { name in
                git_revparse_single(&obj, repo, name)
            })
            defer { git_object_free(obj) }

            let kind: ObjectMetadata.Kind
            switch git_object_type(obj) {
            case GIT_OBJECT_BLOB:   kind = .blob
            case GIT_OBJECT_TREE:   kind = .tree
            case GIT_OBJECT_COMMIT: kind = .commit
            case GIT_OBJECT_TAG:    kind = .tag
            default:
                throw Libgit2Error(code: -1, klass: 0, message: "unknown object type")
            }

            var oid = git_object_id(obj)?.pointee ?? git_oid()
            let sha = formatOID(&oid)

            let size: Int
            switch kind {
            case .blob:
                var blob: OpaquePointer?
                try check(git_blob_lookup(&blob, repo, &oid))
                defer { git_blob_free(blob) }
                size = Int(git_blob_rawsize(blob))
            case .commit:
                // Commit/tag/tree size needs to read the raw object data.
                size = try rawSize(repo: repo, oid: &oid)
            case .tree, .tag:
                size = try rawSize(repo: repo, oid: &oid)
            }
            return ObjectMetadata(sha: sha, kind: kind, size: size)
        }
    }

    /// Read the raw bytes of a blob (or any object, returned untyped).
    /// Mirrors `git cat-file -p` for blobs — for commits/trees you'll
    /// want the structured accessors instead.
    public func catFileBlob(_ revspec: String) async throws -> Data {
        try await withRepository { repo in
            var obj: OpaquePointer?
            try check(revspec.withCString { name in
                git_revparse_single(&obj, repo, name)
            })
            defer { git_object_free(obj) }

            // Peel through tag objects so `cat-file -p v1.0.0` works
            // when v1.0.0 is an annotated tag pointing at a commit.
            var blob: OpaquePointer?
            try check(git_object_peel(&blob, obj, GIT_OBJECT_BLOB))
            defer { git_object_free(blob) }

            let size = Int(git_blob_rawsize(blob))
            guard size > 0, let raw = git_blob_rawcontent(blob) else { return Data() }
            return Data(bytes: raw, count: size)
        }
    }

    private func rawSize(repo: OpaquePointer?, oid: inout git_oid) throws -> Int {
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repo))
        defer { git_odb_free(odb) }
        var raw: OpaquePointer?
        try check(git_odb_read(&raw, odb, &oid))
        defer { git_odb_object_free(raw) }
        return git_odb_object_size(raw)
    }
}
