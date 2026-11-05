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
            variables: [.init(key: "A", value: "1", variableType: .file)],
            inputs: ["n": .int(3), "s": .string("x"), "b": .bool(true), "a": .array(["p", "q"])])

        #expect(pipeline.id == 9877)
        #expect(pipeline.ref == "main")
        #expect(pipeline.webUrl.absoluteString == "https://gitlab.com/group/repo/-/pipelines/9877")
        let (method, url, body) = seen.withLock { $0 }
        #expect(method == "POST")
        #expect(url?.contains("projects/group%2Frepo/pipeline") == true)
        // swift-corelibs-foundation may not expose the body stream to a
        // URLProtocol; assert on the body only where it is readable.
        if !body.isEmpty {
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["ref"] as? String == "main")
            let vars = try #require(json["variables"] as? [[String: String]])
            #expect(vars == [["key": "A", "value": "1", "variable_type": "file"]])
            let inputs = try #require(json["inputs"] as? [String: Any])
            #expect(inputs["n"] as? Int == 3)
            #expect(inputs["s"] as? String == "x")
            #expect(inputs["b"] as? Bool == true)
            #expect(inputs["a"] as? [String] == ["p", "q"])
        }
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
        let body = seen.withLock { $0 }
        if !body.isEmpty {
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["ref"] as? String == "main")
            #expect(json["variables"] == nil)
            #expect(json["inputs"] == nil)
        }
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

    @Test func pipelineCreateRequestEncoding() throws {
        let full = PipelineCreateRequest(
            ref: "main",
            variables: [.init(key: "A", value: "1", variableType: .file)],
            inputs: ["n": .int(3), "b": .bool(true), "a": .array(["p"])])
        let json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder.gitLab().encode(full)) as? [String: Any])
        #expect(json["ref"] as? String == "main")
        let vars = try #require(json["variables"] as? [[String: String]])
        #expect(vars == [["key": "A", "value": "1", "variable_type": "file"]])
        let inputs = try #require(json["inputs"] as? [String: Any])
        #expect(inputs["n"] as? Int == 3)
        #expect(inputs["b"] as? Bool == true)
        #expect(inputs["a"] as? [String] == ["p"])

        let bare = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder.gitLab().encode(PipelineCreateRequest(ref: "main"))) as? [String: Any])
        #expect(bare["variables"] == nil)
        #expect(bare["inputs"] == nil)
    }
}
