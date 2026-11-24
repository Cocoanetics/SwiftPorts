import Foundation

/// Bridges an `async` call to a synchronous return — the shape libgit2's
/// callbacks need, since libgit2 calls them directly on whatever thread
/// is driving the git operation, never on a Swift concurrency executor or
/// the NIO event loop. GitKitSSH's `GitSSHChannel` (GitKit's
/// `SSHTransport.swift` documents that threading contract) and SwiftGit's
/// shell-backed `GitSigner` both cross it.
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
/// watchOS 11. On those older Apple runtimes an actor backed by the
/// same dedicated thread provides the fallback. It keeps the bridge task's
/// actor-isolated work off the pool, but a
/// nonisolated async call can require a cooperative-pool thread.
///
/// Calls nest (issue #290): an operation running on a bridge thread can
/// reach a synchronous callback that bridges again — an LFS pre-push whose
/// remote-heads connect opens an in-process SSH channel. The blocked
/// thread's executor stays checked out of `blockingBridgeThreads` until
/// its call returns, so the nested call gets another dedicated thread
/// instead of queueing behind the one it is blocking. Cancelling an
/// enclosing call's `BlockingBridgeCancellation` also cancels every call
/// nested inside it.
package enum BlockingBridge {
    /// The cancellations of the calls enclosing the current bridge task.
    @TaskLocal private static var enclosingCancellations: [BlockingBridgeCancellation] = []

    package static func runBlocking<T: Sendable>(
        cancellation: BlockingBridgeCancellation? = nil,
        onDiscard: @Sendable (T) -> Void = { _ in },
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let cancellations = enclosingCancellations + (cancellation.map { [$0] } ?? [])
        for cancellation in cancellations { try cancellation.checkCancellation() }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        let thread = blockingBridgeThreads.checkOut()
        defer { blockingBridgeThreads.checkIn(thread) }
        let task: Task<Void, Never>
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) {
            task = Task(executorPreference: thread) {
                await run(on: nil, operation, cancellations: cancellations, box: box, semaphore: semaphore)
            }
        } else {
            let actor = BlockingBridgeExecutor(thread: thread)
            task = Task {
                await run(on: actor, operation, cancellations: cancellations, box: box, semaphore: semaphore)
            }
        }

        let registrations = cancellations.map { ($0, $0.register(task)) }
        defer { for (cancellation, registration) in registrations { cancellation.unregister(registration) } }
        semaphore.wait()
        do {
            for cancellation in cancellations { try cancellation.checkCancellation() }
        } catch {
            // The task may have acquired a resource before cancellation won.
            // Its caller never receives that value, so release it here.
            if case .success(let value) = box.value { onDiscard(value) }
            throw error
        }
        return try box.value.get()
    }

    /// The bridge task's body. `actor` is the older-runtime fallback's isolation; on SE-0417
    /// runtimes it is `nil` and the task-executor preference keeps this on the bridge thread.
    private static func run<T: Sendable>(
        on actor: isolated (any Actor)?,
        _ operation: @Sendable () async throws -> T,
        cancellations: [BlockingBridgeCancellation],
        box: ResultBox<T>,
        semaphore: DispatchSemaphore
    ) async {
        do {
            try Task.checkCancellation()
            let value = try await $enclosingCancellations.withValue(cancellations) { try await operation() }
            box.value = .success(value)
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>!
    }
}

/// Older-Apple-runtime fallback for running the bridge task's actor-isolated wrapper on the
/// call's checked-out dedicated thread — never one a caller is blocking, so nested calls cannot
/// queue behind themselves. Nonisolated operations can still leave this actor under SE-0338,
/// which is why supported runtimes use the task-executor preference above.
private actor BlockingBridgeExecutor {
    private let thread: BlockingBridgeThreadExecutor

    init(thread: BlockingBridgeThreadExecutor) {
        self.thread = thread
    }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        thread.asUnownedSerialExecutor()
    }
}

private let blockingBridgeThreads = BlockingBridgeThreadPool()

/// Dedicated bridge threads, one per call currently blocking a caller. Grows only on nested or
/// concurrent demand; an idle thread is reused, so sequential calls stay on one thread.
private final class BlockingBridgeThreadPool: @unchecked Sendable {
    /// `"BlockingBridge"` is kept under 16 characters so it round-trips through Linux's
    /// `pthread_setname_np`, which truncates/rejects anything past `TASK_COMM_LEN` (16 bytes
    /// including the null terminator).
    private static let name = "BlockingBridge"
    private let lock = NSLock()
    private var idle = [BlockingBridgeThreadExecutor(name: name)]

    func checkOut() -> BlockingBridgeThreadExecutor {
        lock.withLock { idle.popLast() } ?? BlockingBridgeThreadExecutor(name: Self.name)
    }

    func checkIn(_ executor: BlockingBridgeThreadExecutor) {
        lock.withLock { idle.append(executor) }
    }
}

/// A serial and task executor backed by one dedicated OS thread that Swift's cooperative thread
/// pool never manages or schedules onto. Serial-executor and task-executor jobs retain their
/// respective executor identity even though they share the same underlying thread.
private final class BlockingBridgeThreadExecutor: @unchecked Sendable, SerialExecutor {
    private struct QueuedJob {
        let job: UnownedJob
        let usesTaskExecutor: Bool
    }

    private let condition = NSCondition()
    private var jobs: [QueuedJob] = []
    private let threadName: String

    // Name from inside the thread, after dequeuing the first job. On Linux,
    // Foundation's `Thread.start()` stores the pthread handle only after
    // creating the thread; its entry closure can run before that assignment,
    // making even `Thread.current.name = ...` silently do nothing. The first
    // enqueue happens after this executor's initialization (and `start()`)
    // returns, so the queue's condition also synchronizes that assignment.
    // See Thread.start() and Thread.name in swift-corelibs-foundation:
    // https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.3-RELEASE/Sources/Foundation/Thread.swift
    private lazy var thread: Thread = Thread { [weak self] in
        var needsName = true
        while true {
            guard let self else { return }
            self.condition.lock()
            while self.jobs.isEmpty {
                self.condition.wait()
            }
            let job = self.jobs.removeFirst()
            self.condition.unlock()
            if needsName {
                Thread.current.name = self.threadName
                needsName = false
            }
            self.run(job)
        }
    }

    init(name: String) {
        self.threadName = name
        // libgit2's thread blocks on this one (`runBlocking`'s
        // semaphore), typically at user-initiated QoS. Serving it at a
        // lower QoS is a priority inversion, which the Thread
        // Performance Checker flags on every SSH clone and fetch.
        thread.qualityOfService = .userInitiated
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
extension BlockingBridgeThreadExecutor: TaskExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        enqueue(UnownedJob(job), usesTaskExecutor: true)
    }
}
