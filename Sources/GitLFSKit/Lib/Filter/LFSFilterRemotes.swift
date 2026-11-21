import Foundation
import SwiftGit

/// A successful fallback remote persists only for this repository and operation.
final class LFSFilterRemotes: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var operations: [LFSFilterRemotes] = []
    private weak var operation: GitFilterOperationContext?
    private var directory: URL?
    private var selected: String?

    static func forOperation(_ operation: GitFilterOperationContext, source: GitFilterSource) -> LFSFilterRemotes {
        lock.withLock {
            operations.removeAll { $0.operation == nil }
            if let state = operations.first(where: {
                $0.operation === operation && $0.directory == source.gitDirectory
            }) {
                return state
            }
            let state = LFSFilterRemotes()
            state.operation = operation
            state.directory = source.gitDirectory
            operations.append(state)
            return state
        }
    }

    var remote: String? {
        get { Self.lock.withLock { selected } }
        set { Self.lock.withLock { selected = newValue } }
    }
}
