import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HTTPTypes
import Testing
@testable import GitLab

final class TestLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.withLock { body(&value) }
    }
}

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
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
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

@Suite(.serialized)
struct HTTPMockedNetworkTests {
    @Test func conditionalGetReturnsNotModified() async throws {
        let session = MockURLProtocol.session()
        let oldEtag = #""etag-1""#
        let seenIfNoneMatch = TestLockedBox<String?>(nil)
        MockURLProtocol.handler = { request in
            seenIfNoneMatch.withLock {
                $0 = request.value(forHTTPHeaderField: "If-None-Match")
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 304,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!
            return (response, Data())
        }
        let client = APIClient(
            configuration: Configuration(),
            session: session
        )
        let result: Conditional<ConditionalPayload> = try await client.get(
            "cacheable",
            ifNoneMatch: oldEtag)
        #expect(seenIfNoneMatch.withLock { $0 } == oldEtag)
        switch result {
        case .notModified:
            break
        case .modified:
            Issue.record("expected not modified")
        }
    }

    @Test func conditionalGetReturnsModifiedWithETag() async throws {
        let session = MockURLProtocol.session()
        let oldEtag = #""etag-1""#
        let newEtag = #""etag-2""#
        let seenIfNoneMatch = TestLockedBox<String?>(nil)
        MockURLProtocol.handler = { request in
            seenIfNoneMatch.withLock {
                $0 = request.value(forHTTPHeaderField: "If-None-Match")
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "ETag": newEtag,
                ])!
            return (response, Data(#"{"id":1,"name":"cacheable"}"#.utf8))
        }
        let client = APIClient(
            configuration: Configuration(),
            session: session
        )
        let result: Conditional<ConditionalPayload> = try await client.get(
            "cacheable",
            ifNoneMatch: oldEtag)
        #expect(seenIfNoneMatch.withLock { $0 } == oldEtag)
        switch result {
        case .modified(let value, let etag):
            #expect(value.id == 1)
            #expect(value.name == "cacheable")
            #expect(etag == newEtag)
        case .notModified:
            Issue.record("expected modified")
        }
    }

    @Test func rawSurfacesHeaderFieldsAndRateLimitAccessors() async throws {
        let session = MockURLProtocol.session()
        let etag = #""repo-list-1""#
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "ETag": etag,
                    "RateLimit-Remaining": "42",
                    "RateLimit-Reset": "1700000000",
                    "RateLimit-ResetTime": "Tue, 14 Nov 2023 22:13:20 GMT",
                    "Retry-After": "17",
                    "X-GitLab-Request-Id": "01HABCDE",
                ])!
            return (response, Data("[]".utf8))
        }
        let client = APIClient(
            configuration: Configuration(),
            session: session
        )

        let response = try await client.raw(method: .get, path: "projects")

        #expect(response.headerFields[HTTPField.Name("X-GitLab-Request-Id")!] == "01HABCDE")
        #expect(response.headerFields[.contentType] == "application/json")
        #expect(response.etag == etag)
        #expect(response.rateLimitRemaining == 42)
        #expect(response.rateLimitResetAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(response.rateLimitResetTime == "Tue, 14 Nov 2023 22:13:20 GMT")
        #expect(response.retryAfter == 17)
    }
}

private struct ConditionalPayload: Decodable, Sendable {
    let id: Int
    let name: String
}
