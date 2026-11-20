import Foundation
import Crypto
import SwiftGit

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
        _ = try await client.blobSize(ofOID: oid)
        let data = try await client.catFileBlob(oid)
        let pointer = try decode(data)
        let hash = pointer?.oid ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return BlobScanResult(oid: oid, pointer: pointer, contentsSHA256: hash)
    }

    private func decode(_ data: Data) throws -> Pointer? {
        guard data.count < Pointer.blobSizeCutoff else { return nil }
        do {
            return try Pointer.decode(data)
        } catch is PointerError {
            return nil
        }
    }
}
