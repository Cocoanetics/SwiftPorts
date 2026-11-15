import Foundation

/// One libgit2 section at a time, for async callers, without blocking a
/// cooperative thread while they wait.
///
/// ``Libgit2Sandboxing`` serialises with an `NSLock`, held for the whole
/// synchronous run. Waiting for that lock blocks the waiter's thread, and
/// the waiters are Swift concurrency tasks: with enough git operations at
/// once, every cooperative thread waits on the lock. That is a deadlock
/// as soon as the run holding it needs the pool itself — as ``ShellSigner``
/// does, when the shell's process launcher (swift-subprocess) starts an
/// unstructured `Task` that the bridge's executor preference doesn't
/// reach. Taking a turn here first suspends the waiters instead, so the
/// lock is only ever taken uncontended and the pool stays free.
final class Libgit2Turnstile: @unchecked Sendable {
    static let shared = Libgit2Turnstile()

    private let lock = NSLock()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Run `body` once it's this caller's turn, in arrival order.
    func run<T>(_ body: () throws -> T) async rethrows -> T {
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiting.append(turn)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                turn.resume()
            }
        }
        defer { pass() }
        return try body()
    }

    /// Hand the turn to the next caller, or free it.
    private func pass() {
        lock.lock()
        guard !waiting.isEmpty else {
            busy = false
            lock.unlock()
            return
        }
        let next = waiting.removeFirst()
        lock.unlock()
        next.resume()
    }
}
