// Issue #290: a bridged operation that itself reaches a synchronous callback which bridges again
// (an LFS pre-push whose remote-heads connect opens an in-process SSH channel) used to enqueue
// the inner task on the one bridge thread it was blocking, and hang forever.
import Foundation
import Testing
@testable import ForgeKit

struct BlockingBridgeNestingTests {
    @Test("nested runBlocking returns", arguments: [2, 3])
    func nestedCallsReturn(depth: Int) throws {
        let result = try withThreadTimeout(seconds: 10) { try nested(depth: depth) }
        #expect(result == depth)
    }

    @Test("cancelling the outer operation unwinds a blocked inner one")
    func cancellationUnwindsNestedCalls() throws {
        let cancellation = BlockingBridgeCancellation()
        let innerStarted = DispatchSemaphore(value: 0)
        let innerEnded = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            innerStarted.wait()
            cancellation.cancel()
        }
        _ = try withThreadTimeout(seconds: 10) {
            #expect(throws: CancellationError.self) {
                try BlockingBridge.runBlocking(cancellation: cancellation) { () async throws -> Int in
                    defer { innerEnded.signal() }
                    return try BlockingBridge.runBlocking {
                        innerStarted.signal()
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                        return 1
                    }
                }
            }
        }
        #expect(innerEnded.wait(timeout: .now()) == .success)
    }
}

private func nested(depth: Int) throws -> Int {
    guard depth > 0 else { return 0 }
    return try BlockingBridge.runBlocking { try nested(depth: depth - 1) + 1 }
}

/// Runs `operation` on a plain OS thread so a deadlocked bridge fails the test instead of hanging it.
private func withThreadTimeout<T: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () throws -> T
) throws -> T {
    let done = DispatchSemaphore(value: 0)
    let box = TimeoutResultBox<T>()
    Thread.detachNewThread {
        box.value = Result { try operation() }
        done.signal()
    }
    guard done.wait(timeout: .now() + seconds) == .success else {
        Issue.record("operation timed out after \(seconds)s")
        throw CancellationError()
    }
    return try box.value.get()
}

private final class TimeoutResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>!
}
