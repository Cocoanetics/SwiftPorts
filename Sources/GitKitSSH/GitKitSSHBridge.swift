import Foundation

/// Bridges one of SSHKit's `async` calls to a synchronous return — the
/// shape every ``GitSSHChannel``/``GitSSHTransportProvider`` method
/// needs, since libgit2 calls them directly on whatever thread is
/// driving the git operation, never on a Swift concurrency executor or
/// the NIO event loop (GitKit's `SSHTransport.swift` documents this
/// threading contract on `GitSSHChannel`).
///
/// Spawns an unstructured `Task` — which runs on Swift's cooperative
/// thread pool — and blocks the *calling* thread on a semaphore until
/// it finishes. This is the opposite direction from the deadlock the
/// contract warns about (`await`ing a task from the calling thread
/// itself would hop off it); blocking a thread that was never part of
/// the cooperative pool to begin with is safe.
enum GitKitSSHBridge {
    static func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do {
                box.value = .success(try await operation())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.value.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>!
    }
}
