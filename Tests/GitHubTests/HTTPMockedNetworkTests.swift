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

        @Test func createsPullReviewCommentReaction() async throws {
            let session = MockURLProtocol.session()
            let seenMethod = TestLockedBox<String?>(nil)
            let seenPath = TestLockedBox<String?>(nil)
            let seenContentType = TestLockedBox<String?>(nil)
            let seenAccept = TestLockedBox<String?>(nil)
            let seenVersion = TestLockedBox<String?>(nil)
            let seenBody = TestLockedBox<[String: String]?>(nil)

            MockURLProtocol.handler = { request in
                seenMethod.withLock { $0 = request.httpMethod }
                seenPath.withLock { $0 = request.url?.path }
                seenContentType.withLock {
                    $0 = request.value(forHTTPHeaderField: "Content-Type")
                }
                seenAccept.withLock {
                    $0 = request.value(forHTTPHeaderField: "Accept")
                }
                seenVersion.withLock {
                    $0 = request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
                }
                let body = try Self.requestBodyData(from: request)
                let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
                seenBody.withLock { $0 = object }

                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 201,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                let data = Data(#"""
                    {
                      "id": 987,
                      "user": null,
                      "content": "+1",
                      "created_at": "2024-01-15T10:30:00Z"
                    }
                    """#.utf8)
                return (response, data)
            }

            let client = APIClient(
                configuration: Configuration(),
                session: session
            )
            let reaction: Reaction = try await client.send(
                method: .post,
                path: "repos/octocat/Hello-World/pulls/comments/123/reactions",
                body: AddReactionRequest(content: .plus1))

            #expect(seenMethod.withLock { $0 } == "POST")
            #expect(seenPath.withLock { $0 } == "/repos/octocat/Hello-World/pulls/comments/123/reactions")
            #expect(seenContentType.withLock { $0 } == "application/json; charset=utf-8")
            #expect(seenAccept.withLock { $0 } == "application/vnd.github+json")
            #expect(seenVersion.withLock { $0 } == "2022-11-28")
            #expect(seenBody.withLock { $0 } == ["content": "+1"])
            #expect(reaction.id == 987)
            #expect(reaction.user == nil)
            #expect(reaction.content == "+1")
            #expect(reaction.createdAt == ISO8601DateFormatter().date(from: "2024-01-15T10:30:00Z"))
        }

        private static func requestBodyData(from request: URLRequest) throws -> Data {
            if let body = request.httpBody {
                return body
            }
            guard let stream = request.httpBodyStream else {
                return Data()
            }
            stream.open()
            defer { stream.close() }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    throw stream.streamError ?? NSError(
                        domain: "MockURLProtocol",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "failed to read request body"])
                }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            return data
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
    }
}

private struct ConditionalPayload: Decodable, Sendable {
    let id: Int
    let name: String
}
