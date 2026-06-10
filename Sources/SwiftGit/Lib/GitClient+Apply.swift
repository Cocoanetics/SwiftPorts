import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` apply operation
// (`GitKit/Repository+Apply.swift`).
extension GitClient {

    /// Apply a unified-diff patch from `patchData` — `git apply`.
    public func apply(patch patchData: Data, location: ApplyLocation = .workdir) async throws {
        try await withRepository { try $0.apply(patch: patchData, location: location) }
    }
}
