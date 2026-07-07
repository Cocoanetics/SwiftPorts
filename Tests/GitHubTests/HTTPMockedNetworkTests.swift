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

        @Test func decodesCombinedCommitStatus() async throws {
            let session = MockURLProtocol.session()
            let seenPath = TestLockedBox<String?>(nil)
            MockURLProtocol.handler = { request in
                seenPath.withLock { $0 = request.url?.path }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/vnd.github+json"])!
                return (response, Data(combinedStatusJSON.utf8))
            }
            let client = APIClient(
                configuration: Configuration(),
                session: session
            )
            let status: CombinedStatus = try await client.get(
                "repos/octocat/Hello-World/commits/main/status")
            #expect(seenPath.withLock { $0 } == "/repos/octocat/Hello-World/commits/main/status")
            #expect(status.state == "failure")
            #expect(status.sha == "a1b2c3d4")
            #expect(status.totalCount == 1)
            #expect(status.repository.fullName == "octocat/Hello-World")
            #expect(status.statuses.first?.context == "continuous-integration/jenkins")
            #expect(status.statuses.first?.targetUrl?.host == "ci.example.com")
        }

        @Test func decodesCommitStatusList() async throws {
            let session = MockURLProtocol.session()
            let seenPath = TestLockedBox<String?>(nil)
            MockURLProtocol.handler = { request in
                seenPath.withLock { $0 = request.url?.path }
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/vnd.github+json"])!
                return (response, Data("[\(commitStatusJSON)]".utf8))
            }
            let client = APIClient(
                configuration: Configuration(),
                session: session
            )
            let statuses: [CommitStatus] = try await client.get(
                "repos/octocat/Hello-World/commits/a1b2c3d4/statuses")
            #expect(seenPath.withLock { $0 } == "/repos/octocat/Hello-World/commits/a1b2c3d4/statuses")
            #expect(statuses.count == 1)
            #expect(statuses[0].state == "failure")
            #expect(statuses[0].description == "Build failed")
            #expect(statuses[0].creator?.login == "octocat")
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

private let githubUserJSON = #"""
{
  "login": "octocat",
  "id": 1,
  "node_id": "MDQ6VXNlcjE=",
  "avatar_url": "https://github.com/images/error/octocat_happy.gif",
  "html_url": "https://github.com/octocat",
  "type": "User",
  "site_admin": false
}
"""#

private let minimalRepositoryJSON = #"""
{
  "id": 1296269,
  "node_id": "MDEwOlJlcG9zaXRvcnkxMjk2MjY5",
  "name": "Hello-World",
  "full_name": "octocat/Hello-World",
  "owner": \#(githubUserJSON),
  "private": false,
  "html_url": "https://github.com/octocat/Hello-World",
  "description": "This your first repo!",
  "fork": false,
  "url": "https://api.github.com/repos/octocat/Hello-World"
}
"""#

private let commitStatusJSON = #"""
{
  "url": "https://api.github.com/repos/octocat/Hello-World/statuses/1",
  "avatar_url": "https://github.com/images/error/hubot_happy.gif",
  "id": 1,
  "node_id": "MDY6U3RhdHVzMQ==",
  "state": "failure",
  "description": "Build failed",
  "target_url": "https://ci.example.com/1000/output",
  "context": "continuous-integration/jenkins",
  "created_at": "2024-01-01T00:00:00Z",
  "updated_at": "2024-01-01T00:00:30Z",
  "creator": \#(githubUserJSON)
}
"""#

private let combinedStatusJSON = #"""
{
  "state": "failure",
  "statuses": [
    \#(commitStatusJSON)
  ],
  "sha": "a1b2c3d4",
  "total_count": 1,
  "repository": \#(minimalRepositoryJSON),
  "commit_url": "https://api.github.com/repos/octocat/Hello-World/commits/a1b2c3d4",
  "url": "https://api.github.com/repos/octocat/Hello-World/commits/a1b2c3d4/status"
}
"""#
