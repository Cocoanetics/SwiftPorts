import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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

    @Test func mergeRequestDiscussionsFetchUsesEncodedProjectPathAndPaginates() async throws {
        let session = MockURLProtocol.session()
        let seenURLs = TestLockedBox<[String]>([])
        MockURLProtocol.handler = { request in
            seenURLs.withLock { $0.append(request.url!.absoluteString) }
            let components = URLComponents(
                url: request.url!,
                resolvingAgainstBaseURL: false)
            let page = components?.queryItems?
                .first(where: { $0.name == "page" })?.value

            let body: Data
            var headers = ["Content-Type": "application/json"]
            if page == "2" {
                body = Data("""
                [
                  {
                    "id": "disc-2",
                    "individual_note": true,
                    "notes": [
                      {
                        "id": 2,
                        "type": null,
                        "body": "follow-up",
                        "author": {"id": 1, "username": "root"},
                        "system": false
                      }
                    ]
                  }
                ]
                """.utf8)
            } else {
                headers["X-Next-Page"] = "2"
                body = Data("""
                [
                  {
                    "id": "disc-1",
                    "individual_note": false,
                    "notes": [
                      {
                        "id": 1,
                        "type": "DiffNote",
                        "body": "needs work",
                        "author": {"id": 1, "username": "root"},
                        "system": false,
                        "resolvable": true,
                        "resolved": false,
                        "resolved_by": null,
                        "position": {
                          "old_path": "Sources/App.swift",
                          "new_path": "Sources/App.swift",
                          "position_type": "text",
                          "new_line": 42
                        }
                      }
                    ]
                  }
                ]
                """.utf8)
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!
            return (response, body)
        }

        let client = APIClient(
            configuration: Configuration(),
            session: session
        )
        let repo = RepositoryReference(pathSegments: ["group", "sub", "repo"])
        let discussions = try await client.mergeRequestDiscussions(
            project: repo,
            mergeRequestIID: 42,
            query: [URLQueryItem(name: "per_page", value: "1")])

        #expect(discussions.map(\.id) == ["disc-1", "disc-2"])
        #expect(discussions.first?.notes.first?.position?.newLine == 42)
        let urls = seenURLs.withLock { $0 }
        #expect(urls.count == 2)
        #expect(urls[0].contains(
            "projects/group%2Fsub%2Frepo/merge_requests/42/discussions"))
        #expect(urls[0].contains("per_page=1"))
        #expect(urls[1].contains("page=2"))
    }
}

private struct ConditionalPayload: Decodable, Sendable {
    let id: Int
    let name: String
}
