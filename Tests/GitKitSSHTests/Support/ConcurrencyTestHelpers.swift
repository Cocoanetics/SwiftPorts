// Shared helpers for exercising GitKitSSH's bridge under cooperative-thread-pool pressure
// (PR #117's deadlock regression — see `GitKitSSHBridgeThreadingTests`).
import Foundation

struct TestTimeoutError: Error, CustomStringConvertible {
    var description: String { "operation timed out" }
}

/// Serializes every test that calls `saturateCooperativePool`, in case a future one joins
/// `runBlockingCompletesUnderSaturatedPool` — two tests each claiming the *entire* real
/// cooperative pool for themselves must never run at the same time, or each starves the other's
/// own test-harness bookkeeping rather than exercising production code. (Swift Testing's
/// `.serialized` suite trait already covers same-suite ordering; this additionally covers a
/// saturating test added to a different suite later.) Callers: `lock()` before
/// `saturateCooperativePool`, `unlock()` (via `defer`) after releasing it.
let poolSaturationLock = NSLock()

/// Races `operation` against a timer so a regression fails the test instead of hanging the
/// suite forever, the way the old `GitKitSSHBridge.runBlocking` would have under a saturated
/// cooperative thread pool.
func withTestTimeout<T: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Blocks up to `count` cooperative-pool threads at once on a semaphore the test controls —
/// reproducing the shape of `Libgit2Sandboxing.runIsolated` calling into
/// `GitKitSSHBridge.runBlocking` with every pool thread already spoken for. Callers must invoke
/// the returned closure exactly once to release them, even on the failure path.
///
/// Waiting for all `count` saturating tasks to start is itself bounded: the cooperative pool's
/// actual concurrent width is an implementation detail that isn't necessarily `count` (it can be
/// lower, especially under load from unrelated work on a shared machine) — an unconditional wait
/// for every one of them to report in risks hanging this helper itself if the pool never
/// schedules that many at once, rather than exercising the saturation this is meant to test
/// through. Whatever number did start within the deadline is still real pool pressure.
func saturateCooperativePool(count: Int) -> @Sendable () -> Void {
    let release = DispatchSemaphore(value: 0)
    let started = DispatchSemaphore(value: 0)
    for _ in 0..<count {
        Task.detached {
            started.signal()
            // `DispatchSemaphore.wait()` is `noasync` — routed through a plain synchronous
            // function, since this genuinely needs to block the pool thread the detached task
            // landed on, not suspend and give it back.
            blockingWait(release)
        }
    }
    let deadline = DispatchTime.now() + 2
    for _ in 0..<count where started.wait(timeout: deadline) != .success {
        break
    }
    return {
        for _ in 0..<count { release.signal() }
    }
}

private func blockingWait(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

/// Runs `operation` on a brand-new, plain OS thread (never a `Task`) and blocks the calling
/// thread on a semaphore with a wall-clock timeout. Unlike `withTestTimeout`, nothing here —
/// starting `operation`, or this function's own wait — needs a cooperative-pool thread to make
/// progress, so it's safe to use from a test that has deliberately saturated the pool via
/// `saturateCooperativePool`: a `withTestTimeout`-style race would itself need a free pool thread
/// just to schedule its timeout racer, defeating the saturation it's supposed to test through.
func runOnDetachedThread<T: Sendable>(
    timeoutSeconds: Double, _ operation: @escaping @Sendable () throws -> T
) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let box = ThreadResultBox<T>()
    Thread.detachNewThread {
        do {
            box.value = .success(try operation())
        } catch {
            box.value = .failure(error)
        }
        done.signal()
    }
    guard done.wait(timeout: .now() + timeoutSeconds) == .success else {
        throw TestTimeoutError()
    }
    return try box.value.get()
}

private final class ThreadResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>!
}

/// `Thread.current` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`; wrapping the access in a plain
/// synchronous function lets it still be called from an `async`-typed closure.
func currentThreadName() -> String? {
    Thread.current.name
}
