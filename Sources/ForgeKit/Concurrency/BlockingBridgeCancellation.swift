import Foundation

/// Cancellation of the callback work an enclosing synchronous operation waits for.
package final class BlockingBridgeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var tasks: [UUID: @Sendable () -> Void] = [:]

    package init() {}

    package func cancel() {
        let pending = lock.withLock {
            cancelled = true
            return Array(tasks.values)
        }
        for cancel in pending { cancel() }
    }

    package func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    func register<T>(_ task: Task<T, Never>) -> UUID {
        let id = UUID()
        let cancel = lock.withLock {
            tasks[id] = { task.cancel() }
            return cancelled
        }
        if cancel { task.cancel() }
        return id
    }

    func unregister(_ id: UUID) {
        lock.withLock { _ = tasks.removeValue(forKey: id) }
    }
}
