import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GitLab

extension HTTPMockedNetworkTests {
    private static let createdPipelineJSON = """
    {
      "id": 9877,
      "iid": 13,
      "project_id": 7,
      "sha": "deadbeefcafebabe1234567890",
      "ref": "main",
      "status": "created",
      "source": "api",
      "web_url": "https://gitlab.com/group/repo/-/pipelines/9877",
      "created_at": "2024-09-01T12:00:00.000Z",
      "updated_at": "2024-09-01T12:00:00.000Z"
    }
    """

    private func client() -> APIClient {
        APIClient(configuration: Configuration(), session: MockURLProtocol.session())
    }

    @Test func postsRefAndVariablesAndDecodesPipeline() async throws {
        let seen = TestLockedBox<(String?, String?, Data)>((nil, nil, Data()))
        MockURLProtocol.handler = { request in
            seen.withLock {
                $0 = (request.httpMethod, request.url?.absoluteString, requestBodyData(request))
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(Self.createdPipelineJSON.utf8))
        }
        let repo = RepositoryReference(pathSegments: ["group", "repo"])
        let pipeline = try await client().createPipeline(
            project: repo, ref: "main",
            variables: [.init(key: "A", value: "1")])

        #expect(pipeline.id == 9877)
        #expect(pipeline.ref == "main")
        #expect(pipeline.webUrl.absoluteString == "https://gitlab.com/group/repo/-/pipelines/9877")
        let (method, url, body) = seen.withLock { $0 }
        #expect(method == "POST")
        #expect(url?.contains("projects/group%2Frepo/pipeline") == true)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["ref"] as? String == "main")
        let vars = try #require(json["variables"] as? [[String: String]])
        #expect(vars == [["key": "A", "value": "1"]])
    }

    @Test func omitsVariablesWhenEmpty() async throws {
        let seen = TestLockedBox<Data>(Data())
        MockURLProtocol.handler = { request in
            seen.withLock { $0 = requestBodyData(request) }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(Self.createdPipelineJSON.utf8))
        }
        _ = try await client().createPipeline(
            projectIDOrEncodedPath: "group%2Frepo", ref: "main")
        let json = try #require(
            JSONSerialization.jsonObject(with: seen.withLock { $0 }) as? [String: Any])
        #expect(json["ref"] as? String == "main")
        #expect(json["variables"] == nil)
    }

    @Test func mapsClientErrorToAPIError() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (response, Data(#"{"message":"Reference not found"}"#.utf8))
        }
        do {
            _ = try await client().createPipeline(
                projectIDOrEncodedPath: "group%2Frepo", ref: "nope")
            Issue.record("expected APIError")
        } catch let error as APIError {
            guard case .http(let status, _, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(status == 400)
        }
    }
}
