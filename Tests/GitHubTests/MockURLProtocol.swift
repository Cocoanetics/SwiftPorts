import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tiny `Mutex<T>` analogue backed by `NSLock`. Used by the test
/// infrastructure here so the package's deployment floor (macOS 13)
/// stays put — `Synchronization.Mutex` would force the floor up to
/// macOS 15 / iOS 18.
final class TestLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&value) }
    }
}

/// `URLProtocol` you register on a `URLSessionConfiguration` to
/// intercept all requests and return canned responses.
///
/// `handler` is a process-global, so suites that touch it MUST be
/// nested inside a `@Suite(.serialized)` outer suite to prevent
/// concurrent suites from racing each other on it.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let state = TestLockedBox<Handler?>(nil)

    static var handler: Handler? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "MockURLProtocol", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no handler set"]))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
