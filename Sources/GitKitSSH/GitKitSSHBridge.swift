import Foundation

/// Bridges one of SSHKit's `async` calls to a synchronous return — the
/// shape every ``GitSSHChannel``/``GitSSHTransportProvider`` method
/// needs, since libgit2 calls them directly on whatever thread is
/// driving the git operation, never on a Swift concurrency executor or
/// the NIO event loop (GitKit's `SSHTransport.swift` documents this
/// threading contract on `GitSSHChannel`).
///
/// On SE-0417 runtimes, runs `operation` as a task that prefers a
/// dedicated, non-cooperative-pool thread, and blocks the *calling*
/// thread on a semaphore until it finishes.
/// `SwiftGit`'s `GitClient` drives libgit2 from `async` code
/// (`Libgit2Sandboxing.runIsolated`), so that calling thread can itself
/// already be a cooperative-pool thread.
///
/// The task's `TaskExecutor` preference follows it into
/// nonisolated async functions, which is essential here: under SE-0338,
/// calls such as `SSHClient.connect` and `AsyncStream.Iterator.next`
/// otherwise leave the actor executor and resume on the global
/// cooperative pool. The actor alone therefore cannot make the bridge
/// pool-independent end to end.
///
/// `TaskExecutor` is unavailable before macOS 15 / iOS 18 / tvOS 18 /
/// watchOS 11. On those older Apple runtimes a global actor backed by the
/// same dedicated thread provides the fallback. It keeps the bridge task's
/// actor-isolated work off the pool, but a
/// nonisolated async SSHKit call can require a cooperative-pool thread.
enum GitKitSSHBridge {
    static func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            Task(executorPreference: gitKitSSHBridgeThread) {
                do {
                    box.value = .success(try await operation())
                } catch {
                    box.value = .failure(error)
                }
                semaphore.signal()
            }
        } else {
            Task { @GitKitSSHBridgeExecutor in
                do {
                    box.value = .success(try await operation())
                } catch {
                    box.value = .failure(error)
                }
                semaphore.signal()
            }
        }

        semaphore.wait()
        return try box.value.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>!
    }
}

/// Older-Apple-runtime fallback for scheduling the bridge task's actor-isolated wrapper on the
/// same dedicated thread. Nonisolated operations can still leave this actor under SE-0338, which
/// is why supported runtimes use the task-executor preference above.
@globalActor
actor GitKitSSHBridgeExecutor {
    static let shared = GitKitSSHBridgeExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        gitKitSSHBridgeThread.asUnownedSerialExecutor()
    }
}

/// `"GitKitSSHBridge"` is kept to 15 characters so it round-trips through Linux's
/// `pthread_setname_np`, which truncates/rejects anything past `TASK_COMM_LEN` (16 bytes
/// including the null terminator).
private let gitKitSSHBridgeThread = GitKitSSHDedicatedThreadExecutor(name: "GitKitSSHBridge")

/// A serial and task executor backed by one dedicated OS thread that Swift's cooperative thread
/// pool never manages or schedules onto. Serial-executor and task-executor jobs retain their
/// respective executor identity even though they share the same underlying thread.
private final class GitKitSSHDedicatedThreadExecutor: @unchecked Sendable, SerialExecutor {
    private struct QueuedJob {
        let job: UnownedJob
        let usesTaskExecutor: Bool
    }

    private let condition = NSCondition()
    private var jobs: [QueuedJob] = []
    private let threadName: String

    // Named from *inside* the closure, once it's actually running as the
    // thread's entry point, rather than via `thread.name = name` beforehand:
    // on Linux, `Thread`'s `name` setter only reaches the live pthread when
    // the thread calling it is the one being named (`pthread_setname_np`'s
    // single-thread-targeting form) — setting it on a `Thread` that hasn't
    // started yet silently never reaches the OS thread at all there, so
    // `Thread.current.name` (and `pthread_getname_np`) keeps reporting
    // whatever name the process inherited. Darwin doesn't have this gap
    // (confirmed: this threading suite passes there), but naming from
    // within the thread works unconditionally on both.
    private lazy var thread: Thread = Thread { [weak self] in
        Thread.current.name = self?.threadName
        while true {
            guard let self else { return }
            self.condition.lock()
            while self.jobs.isEmpty {
                self.condition.wait()
            }
            let job = self.jobs.removeFirst()
            self.condition.unlock()
            self.run(job)
        }
    }

    init(name: String) {
        self.threadName = name
        thread.start()
    }

    func enqueue(_ job: UnownedJob) {
        enqueue(job, usesTaskExecutor: false)
    }

    private func enqueue(_ job: UnownedJob, usesTaskExecutor: Bool) {
        condition.lock()
        jobs.append(QueuedJob(job: job, usesTaskExecutor: usesTaskExecutor))
        condition.signal()
        condition.unlock()
    }

    private func run(_ queued: QueuedJob) {
        if queued.usesTaskExecutor {
            if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
                queued.job.runSynchronously(on: asUnownedTaskExecutor())
            } else {
                preconditionFailure("TaskExecutor job scheduled on an unavailable runtime")
            }
        } else {
            queued.job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
extension GitKitSSHDedicatedThreadExecutor: TaskExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        enqueue(UnownedJob(job), usesTaskExecutor: true)
    }
}
