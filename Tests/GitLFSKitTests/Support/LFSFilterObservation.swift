import Foundation
import SwiftGit

/// One lifecycle owns both process-wide filter registrations in its test.
final class LFSFilterObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(GitFilterDirection, Bool)] = []
    private var saved: GitClient?
    private var roots: [[String]] = []

    func watch(_ root: URL) {
        lock.withLock { roots.append(root.standardizedFileURL.pathComponents) }
    }

    func watches(_ directory: URL) -> Bool {
        let components = directory.standardizedFileURL.pathComponents
        return lock.withLock { roots.contains { components.starts(with: $0) } }
    }

    func record(_ direction: GitFilterDirection, enabled: Bool, client: GitClient) {
        lock.withLock {
            values.append((direction, enabled))
            saved = client
        }
    }

    func take() -> [(GitFilterDirection, Bool)] {
        lock.withLock {
            defer { values = [] }
            return values
        }
    }

    var client: GitClient? { lock.withLock { saved } }
}
