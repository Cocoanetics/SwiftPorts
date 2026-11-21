import Foundation

/// Retain the original error across the synchronous libgit2 callback boundary.
package struct LFSFilterFailure: Error, LocalizedError {
    let path: String
    let pointer: Pointer
    let underlying: any Error
    package var optionalProcessCommand: String?

    package var errorDescription: String? {
        "Error downloading object: \(path) (\(pointer.oid.prefix(7))): Smudge error: "
            + String(describing: underlying)
    }
}
