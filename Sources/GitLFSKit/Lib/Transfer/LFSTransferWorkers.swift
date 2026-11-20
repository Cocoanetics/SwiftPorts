import Foundation

/// Worker 0 owns the first job and keeps working alone until it sees a
/// successful response. Ending an unsuccessful batch also wakes the waiters.
final class LFSTransferWorkers: @unchecked Sendable {
    private let lock = NSLock()
    private let jobs: [LFSTransferPending]
    private var index = 0
    private var opened: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var succeeded: Bool

    var authenticated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeeded
    }

    init(_ jobs: [LFSTransferPending], authenticated: Bool) {
        self.jobs = jobs
        succeeded = authenticated
        opened = authenticated
    }

    func wait() async {
        await withCheckedContinuation { register($0) }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if opened {
            lock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func next() -> LFSTransferPending? {
        lock.lock()
        defer { lock.unlock() }
        guard index < jobs.count else { return nil }
        defer { index += 1 }
        return jobs[index]
    }

    func success() {
        lock.lock()
        succeeded = true
        lock.unlock()
        finish()
    }

    func finish() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}
