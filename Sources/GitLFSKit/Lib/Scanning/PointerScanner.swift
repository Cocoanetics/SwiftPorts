import Foundation
import Crypto
import CGitKit
@_spi(GitLFSKit) import SwiftGit

/// Shared pointer decoding and full content identity (`lfs.PointerScanner`).
struct PointerScanner: Sendable {
    let client: GitClient

    /// Pointer-only scans reject large blobs from the header, without reading them.
    func readPointer(_ oid: String) async throws -> Pointer? {
        guard let size = try await client.blobSize(ofOID: oid),
              size < Pointer.blobSizeCutoff else { return nil }
        let data = try await client.catFileBlob(oid)
        return try decode(data)
    }

    /// Valid small pointers identify their target; all other blobs identify raw bytes.
    func scanBlob(_ oid: String) async throws -> BlobScanResult {
        // A direct ODB lookup preserves missing-object errors; revparse in
        // catFileBlob would turn them into generic missing-revision errors.
        let size = try await client.blobSize(ofOID: oid)
        if let size, size < Pointer.blobSizeCutoff {
            let data = try await client.catFileBlob(oid)
            let pointer = try decode(data)
            let hash = pointer?.oid ?? Self.sha256(data)
            return BlobScanResult(oid: oid, pointer: pointer, contentsSHA256: hash)
        }
        guard let size else {
            let data = try await client.catFileBlob(oid)
            return BlobScanResult(oid: oid, pointer: nil, contentsSHA256: Self.sha256(data))
        }

        var hasher = SHA256()
        var objectHasher = Insecure.SHA1()
        objectHasher.update(data: Data("blob \(size)\0".utf8))
        try await client.forEachBlobChunk(ofOID: oid) {
            hasher.update(bufferPointer: $0)
            objectHasher.update(bufferPointer: $0)
        }
        let actualOID = Self.hexadecimal(objectHasher.finalize())
        guard actualOID.caseInsensitiveCompare(oid) == .orderedSame else {
            throw Libgit2Error(
                code: GIT_EMISMATCH.rawValue,
                klass: Int32(GIT_ERROR_ODB.rawValue),
                message: "object hash mismatch - expected \(oid) but got \(actualOID)")
        }
        return BlobScanResult(oid: oid, pointer: nil,
                              contentsSHA256: Self.hexadecimal(hasher.finalize()))
    }

    private func decode(_ data: Data) throws -> Pointer? {
        guard data.count < Pointer.blobSizeCutoff else { return nil }
        do {
            return try Pointer.decode(data)
        } catch is PointerError {
            return nil
        }
    }

    private static func sha256(_ data: Data) -> String {
        hexadecimal(SHA256.hash(data: data))
    }

    private static func hexadecimal<Bytes: Sequence>(_ bytes: Bytes) -> String
        where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
