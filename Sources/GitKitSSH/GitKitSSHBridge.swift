import Foundation

/// Bridges one of SSHKit's `async` calls to a synchronous return — the
/// shape every ``GitSSHChannel``/``GitSSHTransportProvider`` method
/// needs, since libgit2 calls them directly on whatever thread is
/// driving the git operation, never on a Swift concurrency executor or
/// the NIO event loop (GitKit's `SSHTransport.swift` documents this
/// threading contract on `GitSSHChannel`).
///
/// Runs `operation` as a `Task` isolated to ``GitKitSSHBridgeExecutor`` —
/// a global actor backed by one dedicated, non-cooperative-pool thread —
/// and blocks the *calling* thread on a semaphore until it finishes.
/// `SwiftGit`'s `GitClient` drives libgit2 from `async` code
/// (`Libgit2Sandboxing.runIsolated`), so that calling thread can itself
/// already be a cooperative-pool thread. Writing the isolation on the
/// `Task` closure itself (`Task { @GitKitSSHBridgeExecutor in ... }`,
/// not a plain `Task { ... }`) is what keeps even the task's *first*
/// scheduling off the cooperative pool — the same mechanism
/// `Task { @MainActor in ... }` uses to reach the main thread without
/// ever touching the pool.
///
/// `operation`'s own parameter type carries the `@GitKitSSHBridgeExecutor`
/// isolation too, not just the `Task` closure that calls it — isolation
/// is a property of a function's *type*, not something it inherits from
/// whoever calls it, so a plain `@Sendable () async throws -> T` operand
/// would run as `nonisolated` the instant it's invoked, hopping off this
/// dedicated thread and right back onto the cooperative pool for its own
/// body (confirmed empirically: `Thread.current` inside such an operand
/// came back as an anonymous pool thread, not this file's dedicated
/// one, until the parameter picked up the same isolation). With both
/// pinned to the same actor, every resumption after every `await` inside
/// `operation` — not just its first call — stays on that one dedicated
/// thread, so this blocking wait never needs a pool thread to free up to
/// make progress: on a pool constrained to one thread, or with every
/// pool thread already parked in a `runBlocking` call of its own, the
/// task still runs and the semaphore still gets signaled.
///
/// (`Task(executorPreference:)` / `TaskExecutor` would make this
/// simpler, but both the protocol and `DispatchQueue`'s conformance to
/// it require macOS 15/15.4 — newer than this package's macOS 13
/// floor.)
enum GitKitSSHBridge {
    static func runBlocking<T: Sendable>(_ operation: @escaping @GitKitSSHBridgeExecutor @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task { @GitKitSSHBridgeExecutor in
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

/// Global actor every ``GitKitSSHBridge/runBlocking(_:)`` task — and the `operation` it runs —
/// is isolated to. `shared`'s single ``GitKitSSHDedicatedThreadExecutor`` is the only executor
/// this actor ever runs on, so nothing isolated to it — first scheduling or any later
/// resumption — depends on Swift's cooperative thread pool having a free thread.
@globalActor
actor GitKitSSHBridgeExecutor {
    static let shared = GitKitSSHBridgeExecutor()

    /// `"GitKitSSHBridge"` — kept to 15 characters so it round-trips through Linux's
    /// `pthread_setname_np`, which truncates/rejects anything past `TASK_COMM_LEN` (16 bytes
    /// including the null terminator).
    private let thread = GitKitSSHDedicatedThreadExecutor(name: "GitKitSSHBridge")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        thread.asUnownedSerialExecutor()
    }
}

/// A `SerialExecutor` backed by one dedicated OS thread that Swift's cooperative thread pool
/// never manages or schedules onto — jobs queue up and run strictly one at a time, each only
/// until its next suspension point, same as any other serial executor, just on a thread that
/// isn't shared with (or contended for by) anything else in the process.
private final class GitKitSSHDedicatedThreadExecutor: @unchecked Sendable, SerialExecutor {
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []

    private lazy var thread: Thread = Thread { [weak self] in
        while true {
            guard let self else { return }
            self.condition.lock()
            while self.jobs.isEmpty {
                self.condition.wait()
            }
            let job = self.jobs.removeFirst()
            self.condition.unlock()
            job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    init(name: String) {
        thread.name = name
        thread.start()
    }

    func enqueue(_ job: UnownedJob) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
