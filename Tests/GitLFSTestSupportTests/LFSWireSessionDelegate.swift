import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Observes the end of a wire client's session, including its delegate callbacks.
final class LFSWireSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var invalidated = false
    private var completion: CheckedContinuation<Void, Never>?

    var isInvalidated: Bool {
        lock.withLock { invalidated }
    }

    func invalidate(_ session: URLSession) async {
        // A cancelled test must still wait for the delegate callback.
        await withCheckedContinuation { continuation in
            lock.withLock { completion = continuation }
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        let continuation = lock.withLock {
            invalidated = true
            let continuation = completion
            completion = nil
            return continuation
        }
        continuation?.resume()
    }
}
