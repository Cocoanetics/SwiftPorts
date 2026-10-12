// Regression coverage for the PR #117 review finding (HIGH): `GitKitSSHBridge.runBlocking`
// used to spawn a plain, unisolated `Task`, which Swift schedules onto its cooperative thread
// pool. `SwiftGit`'s `GitClient` drives libgit2 from `async` code (`Libgit2Sandboxing.runIsolated`,
// deliberately synchronous and `NSLock`-based), so the thread calling into `runBlocking` can
// itself already be a cooperative-pool thread — blocking it on a semaphore while the spawned
// `Task` waits for a pool thread of its own to free up deadlocks outright once the pool is
// exhausted (a single-core CI/agent sandbox, or several concurrent GitKitSSH operations in one
// process, per issue #113's stated MissionControl adoption).
//
// The fix pins every `runBlocking` task to `GitKitSSHBridgeExecutor`, a global actor backed by
// one dedicated, non-pool thread (`GitKitSSHDedicatedThreadExecutor`), so nothing here — first
// scheduling or any later resumption — ever depends on the cooperative pool having a free thread.
// See `GitKitSSHEndToEndTests.cloneCompletesUnderSaturatedCooperativePool` for the same guarantee
// exercised through a real clone over a throwaway `sshd`.
import Foundation
import Testing
@testable import GitKitSSH

// `.serialized`: `runBlockingCompletesUnderSaturatedPool` deliberately occupies every thread in
// the real cooperative pool. Swift Testing runs a suite's tests concurrently by default, so
// without this, that saturation would race against this suite's other tests' own pool usage
// (and vice versa) rather than against production code — a false failure in the test harness,
// not a regression in `GitKitSSHBridge`.
@Suite("GitKitSSHBridge threading", .serialized)
struct GitKitSSHBridgeThreadingTests {

    @Test("runBlocking always runs its operation on its own dedicated thread, never the cooperative pool")
    func runBlockingUsesDedicatedThread() throws {
        // `Thread.current` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — `runBlocking`'s operation
        // parameter type is `async`, so even this non-suspending closure counts as an
        // asynchronous context; routing through a plain synchronous function sidesteps that.
        let first = try GitKitSSHBridge.runBlocking { currentThreadName() }
        let second = try GitKitSSHBridge.runBlocking { currentThreadName() }
        #expect(first == "GitKitSSHBridge")
        #expect(first == second)
    }

    @Test("runBlocking completes even with every cooperative-pool thread already blocked")
    func runBlockingCompletesUnderSaturatedPool() throws {
        poolSaturationLock.lock()
        defer { poolSaturationLock.unlock() }

        let release = saturateCooperativePool(count: ProcessInfo.processInfo.activeProcessorCount)
        defer { release() }

        // Verified from a plain OS thread, not a `Task` — this test has just exhausted the real
        // cooperative pool, so even the timeout race in `withTestTimeout` would have nowhere to
        // schedule its own racer task.
        let result = try runOnDetachedThread(timeoutSeconds: 5) {
            try GitKitSSHBridge.runBlocking { 42 }
        }
        #expect(result == 42)
    }

    @Test("two concurrent runBlocking calls both complete without deadlocking each other")
    func concurrentRunBlockingCallsBothComplete() async throws {
        let (first, second) = try await withTestTimeout(seconds: 5) {
            async let first = Task.detached {
                try GitKitSSHBridge.runBlocking { () async throws -> Int in
                    try await Task.sleep(nanoseconds: 100_000_000)
                    return 1
                }
            }.value
            async let second = Task.detached {
                try GitKitSSHBridge.runBlocking { () async throws -> Int in
                    try await Task.sleep(nanoseconds: 100_000_000)
                    return 2
                }
            }.value
            return try await (first, second)
        }
        #expect(first == 1)
        #expect(second == 2)
    }
}
