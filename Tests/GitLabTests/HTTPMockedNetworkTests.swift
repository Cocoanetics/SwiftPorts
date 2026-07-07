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

    @Test func sendsMergeRequestCreateRequest() async throws {
        let session = MockURLProtocol.session()
        let seenMethod = TestLockedBox<String?>(nil)
        let seenURL = TestLockedBox<String?>(nil)
        let seenBody = TestLockedBox<Data?>(nil)

        MockURLProtocol.handler = { request in
            seenMethod.withLock { $0 = request.httpMethod }
            seenURL.withLock { $0 = request.url?.absoluteString }
            seenBody.withLock {
                let raw = requestBodyData(request)
                $0 = raw.isEmpty ? nil : raw
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            let body = Data("""
            {
              "id": 10, "iid": 2, "project_id": 7,
              "title": "Add foo", "description": "Long body",
              "state": "opened",
              "target_branch": "main", "source_branch": "feat/foo",
              "labels": ["bug"], "web_url": "https://gitlab.example.com/group/repo/-/merge_requests/2",
              "detailed_merge_status": "checking"
            }
            """.utf8)
            return (response, body)
        }

        let client = APIClient(
            configuration: Configuration(host: "gitlab.example.com", token: "token"),
            session: session)
        let request = MergeRequestCreateRequest(
            title: "Add foo",
            sourceBranch: "feat/foo",
            targetBranch: "main",
            description: "Long body",
            labels: "bug",
            removeSourceBranch: true)
        let merge: MergeRequest = try await client.send(
            method: .post,
            path: "projects/group%2Frepo/merge_requests",
            body: request)

        #expect(merge.iid == 2)
        #expect(merge.detailedMergeStatus == "checking")
        #expect(seenMethod.withLock { $0 } == "POST")
        #expect(seenURL.withLock { $0 }?.contains("projects/group%2Frepo/merge_requests") == true)

        if let bodyData = seenBody.withLock({ $0 }), !bodyData.isEmpty {
            let object = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            #expect(object?["title"] as? String == "Add foo")
            #expect(object?["source_branch"] as? String == "feat/foo")
            #expect(object?["target_branch"] as? String == "main")
            #expect(object?["description"] as? String == "Long body")
            #expect(object?["labels"] as? String == "bug")
            #expect(object?["remove_source_branch"] as? Bool == true)
        }
    }

    @Test func rawSurfacesHeaderFieldsAndETag() async throws {
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
    }
}

private struct ConditionalPayload: Decodable, Sendable {
    let id: Int
    let name: String
}

private func requestBodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }

    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    var data = Data()
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count > 0 {
            data.append(buffer, count: count)
        } else {
            break
        }
    }
    return data
}
