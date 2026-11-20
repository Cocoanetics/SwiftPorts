/// The Git identity and full content identity of a scanned blob.
struct BlobScanResult: Sendable, Equatable {
    let oid: String
    let pointer: Pointer?
    let contentsSHA256: String
}
