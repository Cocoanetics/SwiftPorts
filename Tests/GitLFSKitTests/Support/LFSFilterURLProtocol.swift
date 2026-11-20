import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Deterministic 401 → credential retry, independent of other HTTP suites.
final class LFSFilterURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let authed = request.value(forHTTPHeaderField: "Authorization") != nil
        let response = HTTPURLResponse(
            url: request.url!, statusCode: authed ? 200 : 401,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
