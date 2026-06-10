import Foundation
import GitKit

// Sandbox-aware delegation onto the pure `Repository` checkout operations
// (`GitKit/Repository+Checkout.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off.
extension GitClient {

    /// Create a new branch (or reset an existing one with `force=true`)
    /// at `startPoint`, then check it out (`git checkout -b` / `-B`).
    @discardableResult
    public func checkoutNewBranch(
        name: String,
        startPoint: String = "HEAD",
        force: Bool = false
    ) async throws -> CheckoutBranchOutcome {
        try await withRepository {
            try $0.checkoutNewBranch(name: name, startPoint: startPoint, force: force)
        }
    }

    /// `git checkout -- <paths>`: restore the listed paths in the
    /// working tree to match the index.
    public func checkoutPaths(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await withRepository { try $0.checkoutPaths(paths) }
    }

    /// `git checkout <ref> -- <paths>`: restore listed paths from
    /// `ref`'s tree into both the index and working tree.
    public func checkoutPaths(_ paths: [String], from ref: String) async throws {
        guard !paths.isEmpty else { return }
        try await withRepository { try $0.checkoutPaths(paths, from: ref) }
    }
}
