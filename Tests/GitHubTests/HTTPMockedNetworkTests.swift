import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // HTTPURLResponse is in this module on Linux
#endif
import HTTPTypes
import Testing
@testable import GitHub

/// Suites that touch `MockURLProtocol.handler` (a process global) live
/// here, nested under a single `.serialized` parent so they can't race
/// each other on the handler.
@Suite(.serialized)
struct HTTPMockedNetworkTests {

    @Suite struct APIClientTests {
        @Test func decodesGetResponse() async throws {
            let session = MockURLProtocol.session()
            let json = try FixtureLoader.data("repo_octocat_hello_world")
            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/vnd.github+json"])!
                return (response, json)
            }
            let client = APIClient(
                configuration: Configuration(),
                session: session
            )
            let repo: Repository = try await client.get("repos/octocat/Hello-World")
            #expect(repo.fullName == "octocat/Hello-World")
        }

        @Test func mapsNotFound() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (response, Data(#"{"message":"Not Found"}"#.utf8))
            }
            let client = APIClient(
                configuration: Configuration(),
                session: session
            )
            await #expect(throws: APIError.self) {
                let _: Repository = try await client.get("repos/no/such")
            }
        }

        @Test func mapsRateLimited() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "X-RateLimit-Remaining": "0",
                        "X-RateLimit-Reset": "1700000000",
                    ])!
                return (response, Data(#"{"message":"API rate limit exceeded"}"#.utf8))
            }
            let client = APIClient(
                configuration: Configuration(),
                session: session
            )
            do {
                let _: Repository = try await client.get("repos/x/y")
                Issue.record("expected throw")
            } catch let APIError.rateLimited(resetAt, remaining, _) {
                #expect(remaining == 0)
                #expect(resetAt != nil)
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        @Test func paginatesLinkHeader() async throws {
            let session = MockURLProtocol.session()
            let pageNumber = TestLockedBox<Int>(0)
            MockURLProtocol.handler = { request in
                let n = pageNumber.withLock { v -> Int in v += 1; return v }
                let body: Data
                var headers: [String: String] = ["Content-Type": "application/json"]
                if n == 1 {
                    body = Data(#"[{"id":1,"name":"a"}]"#.utf8)
                    headers["Link"] = #"<https://api.github.com/x?page=2>; rel="next""#
                } else {
                    body = Data(#"[{"id":2,"name":"b"}]"#.utf8)
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
            struct Item: Codable, Sendable { let id: Int; let name: String }
            let items: [Item] = try await client.paginate("x")
            #expect(items.count == 2)
            #expect(items.map(\.id) == [1, 2])
        }

        @Test func rawSurfacesCompleteHeaderFields() async throws {
            // `gh api --include` renders every response header, so
            // APIResponse must carry the full set — not just the
            // handful of parsed convenience properties.
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-GitHub-Request-Id": "C0DE:BEEF",
                        "Server": "github.com",
                    ])!
                return (response, Data("{}".utf8))
            }
            let client = APIClient(
                configuration: Configuration(),
                session: session
            )
            let response = try await client.raw(method: .get, path: "user")
            #expect(response.headerFields[HTTPField.Name("X-GitHub-Request-Id")!] == "C0DE:BEEF")
            #expect(response.headerFields[HTTPField.Name("Server")!] == "github.com")
            #expect(response.headerFields[.contentType] == "application/json")
        }

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
    }

    @Suite struct GraphQLClientTests {
        @Test func decodesViewerData() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let body = Data(#"""
                    {"data":{"viewer":{"login":"octocat","name":"The Octocat","url":"https://github.com/octocat"}}}
                    """#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let client = GraphQLClient(
                configuration: Configuration(),
                session: session)
            let result: ViewerQuery = try await client.query(ViewerQuery.query)
            #expect(result.viewer.login == "octocat")
            #expect(result.viewer.name == "The Octocat")
        }

        @Test func throwsOnGraphQLErrors() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let body = Data(#"""
                    {"errors":[{"message":"Field 'nope' doesn't exist on type 'Query'"}]}
                    """#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let client = GraphQLClient(
                configuration: Configuration(),
                session: session)
            await #expect(throws: GraphQLAggregateError.self) {
                let _: ViewerQuery = try await client.query("query { nope }")
            }
        }

        @Test func rawQueryReturnsBothDataAndErrors() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let body = Data(#"""
                    {"data":{"viewer":{"login":"octocat","name":null,"url":"https://github.com/octocat"}},"errors":[{"message":"deprecated field"}]}
                    """#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let client = GraphQLClient(
                configuration: Configuration(),
                session: session)
            let envelope: GraphQLResponse<ViewerQuery> = try await client.rawQuery(ViewerQuery.query)
            #expect(envelope.data?.viewer.login == "octocat")
            #expect(envelope.errors?.count == 1)
        }

        @Test func queriesReviewThreadsByPR() async throws {
            let session = MockURLProtocol.session()
            let captured = TestLockedBox<[String: Any]?>(nil)
            MockURLProtocol.handler = { request in
                captured.withLock {
                    $0 = try? JSONSerialization.jsonObject(
                        with: requestBodyData(request)) as? [String: Any]
                }
                let body = Data(#"""
                    {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
                      {"id":"PRRT_kw1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"databaseId":101},{"databaseId":102}]}},
                      {"id":"PRRT_kw2","isResolved":true,"isOutdated":true,"comments":{"nodes":[{"databaseId":201}]}}
                    ]}}}}}
                    """#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let client = GraphQLClient(
                configuration: Configuration(),
                session: session)
            let response: PullRequestReviewThreadsResponse = try await client.query(
                PullRequestQueries.reviewThreads,
                variables: [
                    "owner": .string("octocat"),
                    "name": .string("Hello-World"),
                    "number": .int(42),
                    "first": .int(100),
                ])

            let threads = try #require(response.repository?.pullRequest?.reviewThreads.nodes)
            #expect(threads.count == 2)
            let match = threads.first { thread in
                thread.comments.nodes.contains { $0.databaseId == 102 }
            }
            #expect(match?.id == "PRRT_kw1")
            #expect(match?.isResolved == false)
            #expect(match?.isOutdated == false)

            if let requestJSON = captured.withLock({ $0 }) {
                #expect((requestJSON["query"] as? String)?.contains("reviewThreads(first: $first)") == true)
                let variables = try #require(requestJSON["variables"] as? [String: Any])
                #expect(variables["owner"] as? String == "octocat")
                #expect(variables["name"] as? String == "Hello-World")
                #expect(variables["number"] as? Int == 42)
                #expect(variables["first"] as? Int == 100)
            }
        }

        @Test func resolvesReviewThread() async throws {
            let session = MockURLProtocol.session()
            let captured = TestLockedBox<[String: Any]?>(nil)
            MockURLProtocol.handler = { request in
                captured.withLock {
                    $0 = try? JSONSerialization.jsonObject(
                        with: requestBodyData(request)) as? [String: Any]
                }
                let body = Data(#"""
                    {"data":{"resolveReviewThread":{"thread":{"id":"PRRT_kw1","isResolved":true}}}}
                    """#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let client = GraphQLClient(
                configuration: Configuration(),
                session: session)
            let response: ResolveReviewThreadResponse = try await client.query(
                PullRequestMutations.resolveReviewThread,
                variables: ["threadId": .string("PRRT_kw1")])

            #expect(response.resolveReviewThread.thread.id == "PRRT_kw1")
            #expect(response.resolveReviewThread.thread.isResolved == true)

            if let requestJSON = captured.withLock({ $0 }) {
                #expect((requestJSON["query"] as? String)?.contains("resolveReviewThread") == true)
                let variables = try #require(requestJSON["variables"] as? [String: Any])
                #expect(variables["threadId"] as? String == "PRRT_kw1")
            }
        }

        @Test func unresolvesReviewThread() async throws {
            let session = MockURLProtocol.session()
            let captured = TestLockedBox<[String: Any]?>(nil)
            MockURLProtocol.handler = { request in
                captured.withLock {
                    $0 = try? JSONSerialization.jsonObject(
                        with: requestBodyData(request)) as? [String: Any]
                }
                let body = Data(#"""
                    {"data":{"unresolveReviewThread":{"thread":{"id":"PRRT_kw1","isResolved":false}}}}
                    """#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                return (response, body)
            }
            let client = GraphQLClient(
                configuration: Configuration(),
                session: session)
            let response: UnresolveReviewThreadResponse = try await client.query(
                PullRequestMutations.unresolveReviewThread,
                variables: ["threadId": .string("PRRT_kw1")])

            #expect(response.unresolveReviewThread.thread.id == "PRRT_kw1")
            #expect(response.unresolveReviewThread.thread.isResolved == false)

            if let requestJSON = captured.withLock({ $0 }) {
                #expect((requestJSON["query"] as? String)?.contains("unresolveReviewThread") == true)
                let variables = try #require(requestJSON["variables"] as? [String: Any])
                #expect(variables["threadId"] as? String == "PRRT_kw1")
            }
        }
    }
}

private struct ConditionalPayload: Decodable, Sendable {
    let id: Int
    let name: String
}

private func requestBodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return Data()
    }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data
}
