#if !os(Android)  // command tests depend on ArgumentParser
import ArgumentParser
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import GitHub
@testable import GhCommand

extension HTTPMockedNetworkTests {
    @Suite struct PrMergeAutoMergeTests {
        @Test(arguments: ["merge", "squash", "rebase"])
        func enablesAutoMerge(method: String) async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/graphql")
                let body = try Self.body(request)
                let call = calls.withLock { value in value += 1; return value }
                if call == 1 {
                    if let variables = body["variables"] as? [String: Any],
                       let query = body["query"] as? String {
                        #expect(variables["owner"] as? String == "cli")
                        #expect(variables["name"] as? String == "cli")
                        #expect(variables["number"] as? Int == 1)
                        #expect(query.contains("mergeStateStatus"))
                    }
                    return Self.response(request, json: Self.status("BLOCKED"))
                }
                if let variables = body["variables"] as? [String: Any],
                   let query = body["query"] as? String {
                    #expect(query.contains("mutation($input: EnablePullRequestAutoMergeInput!)"))
                    #expect(query.contains("enablePullRequestAutoMerge(input: $input)"))
                    let input = try #require(variables["input"] as? [String: String])
                    #expect(input["pullRequestId"] == "PR_node")
                    #expect(input["mergeMethod"] == method.uppercased())
                    #expect(input["commitHeadline"] == "Custom subject")
                    #expect(input["commitBody"] == "Custom body")
                    #expect(input["commitTitle"] == nil)
                    #expect(input["commitMessage"] == nil)
                }
                return Self.response(
                    request,
                    json: #"{"data":{"enablePullRequestAutoMerge":{"clientMutationId":null}}}"#)
            }
            var args = ["1", "--auto", "--subject", "Custom subject", "--body", "Custom body"]
            args.append("--\(method)")
            try await Self.run(args, session: session)
            #expect(calls.withLock { $0 } == 2)
        }

        @Test(arguments: ["CLEAN", "BLOCKED"])
        func requiresMergeMethodOutsideMergeQueue(status: String) async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                calls.withLock { $0 += 1 }
                return Self.response(request, json: Self.status(status))
            }
            await #expect(throws: ValidationError.self) {
                try await Self.run(["1", "--auto"], session: session)
            }
            #expect(calls.withLock { $0 } == 1)
        }

        @Test(arguments: ["CLEAN", "BLOCKED"])
        func mergeQueueUsesAutoMergeWhenMethodIsOmitted(status: String) async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                let call = calls.withLock { value in value += 1; return value }
                if call == 1 {
                    let body = try Self.body(request)
                    if let query = body["query"] as? String {
                        #expect(query.contains("isMergeQueueEnabled"))
                    }
                    return Self.response(request, json: Self.status(status, mergeQueueEnabled: true))
                }
                let body = try Self.body(request)
                if let query = body["query"] as? String,
                   let variables = body["variables"] as? [String: Any] {
                    #expect(query.contains("enablePullRequestAutoMerge(input: $input)"))
                    let input = try #require(variables["input"] as? [String: String])
                    #expect(input["pullRequestId"] == "PR_node")
                    #expect(input["mergeMethod"] == "MERGE")
                }
                return Self.response(
                    request,
                    json: #"{"data":{"enablePullRequestAutoMerge":{"clientMutationId":null}}}"#)
            }
            try await Self.run(["1", "--auto"], session: session)
            #expect(calls.withLock { $0 } == 2)
        }

        @Test func disablesAutoMergeWithoutMerging() async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path == "/graphql")
                let call = calls.withLock { value in value += 1; return value }
                if call == 1 { return Self.response(request, json: Self.status("CLEAN")) }
                let body = try Self.body(request)
                if let query = body["query"] as? String,
                   let variables = body["variables"] as? [String: Any] {
                    #expect(query.contains("disablePullRequestAutoMerge(input: $input)"))
                    #expect(query.contains("DisablePullRequestAutoMergeInput!"))
                    let input = try #require(variables["input"] as? [String: String])
                    #expect(input == ["pullRequestId": "PR_node"])
                }
                return Self.response(
                    request,
                    json: #"{"data":{"disablePullRequestAutoMerge":{"clientMutationId":null}}}"#)
            }
            try await Self.run(["1", "--disable-auto", "--squash", "--subject", "ignored"], session: session)
            #expect(calls.withLock { $0 } == 2)
        }

        @Test(arguments: ["CLEAN", "HAS_HOOKS", "UNSTABLE"])
        func autoMergesImmediatelyWhenReady(status: String) async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                let call = calls.withLock { value in value += 1; return value }
                if call == 1 { return Self.response(request, json: Self.status(status)) }
                #expect(request.httpMethod == "PUT")
                #expect(request.url?.path == "/repos/cli/cli/pulls/1/merge")
                let body = try Self.body(request)
                if !body.isEmpty { #expect(body["merge_method"] as? String == "squash") }
                return Self.response(request, json: #"{"merged":true,"sha":"abcdef0123456789"}"#)
            }
            try await Self.run(["1", "--auto", "--squash"], session: session)
            #expect(calls.withLock { $0 } == 2)
        }

        @Test(arguments: ["--auto", "--disable-auto"])
        func propagatesMutationErrors(flag: String) async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                let call = calls.withLock { value in value += 1; return value }
                if call == 1 { return Self.response(request, json: Self.status("BLOCKED")) }
                return Self.response(request, json: #"{"data":{},"errors":[{"message":"Auto-merge is not allowed"}]}"#)
            }
            await #expect(throws: GraphQLAggregateError.self) {
                try await Self.run(["1", flag, "--merge"], session: session)
            }
            #expect(calls.withLock { $0 } == 2)
        }

        @Test func rejectsConflictingFlagsBeforeNetworking() throws {
            #expect(throws: (any Error).self) {
                try PrMerge.parse(["1", "--auto", "--disable-auto"])
            }
            #expect(throws: (any Error).self) {
                try PrMerge.parse(["1", "--auto", "--squash", "--rebase"])
            }
        }

        @Test(arguments: [true, false])
        func distinguishesOmittedAndEmptyCommitBody(explicitEmpty: Bool) async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                let call = calls.withLock { value in value += 1; return value }
                if call == 1 { return Self.response(request, json: Self.status("BLOCKED")) }
                let body = try Self.body(request)
                if let variables = body["variables"] as? [String: Any] {
                    let input = try #require(variables["input"] as? [String: String])
                    #expect(input["commitHeadline"] == nil)
                    #expect(input["commitBody"] == (explicitEmpty ? "" : nil))
                }
                return Self.response(
                    request,
                    json: #"{"data":{"enablePullRequestAutoMerge":{"clientMutationId":null}}}"#)
            }
            let args = ["1", "--auto", "--merge"] + (explicitEmpty ? ["--body", ""] : [])
            try await Self.run(args, session: session)
            #expect(calls.withLock { $0 } == 2)
        }

        @Test func missingPullRequestDoesNotMutate() async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                calls.withLock { $0 += 1 }
                return Self.response(request, json: #"{"data":{"repository":{"pullRequest":null}}}"#)
            }
            await #expect(throws: ValidationError.self) {
                try await Self.run(["1", "--auto", "--squash"], session: session)
            }
            #expect(calls.withLock { $0 } == 1)
        }

        @Test func mergedPullRequestDoesNotEnableAutoMerge() async throws {
            let session = MockURLProtocol.session()
            let calls = TestLockedBox(0)
            MockURLProtocol.handler = { request in
                calls.withLock { $0 += 1 }
                let json = Self.status("UNKNOWN").replacingOccurrences(of: "OPEN", with: "MERGED")
                return Self.response(request, json: json)
            }
            try await Self.run(["1", "--auto", "--merge"], session: session)
            #expect(calls.withLock { $0 } == 1)
        }

        @Test func ordinaryMergeUsesOnlyREST() async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                #expect(request.httpMethod == "PUT")
                #expect(request.url?.path == "/repos/cli/cli/pulls/1/merge")
                return Self.response(request, json: #"{"merged":true,"sha":"abcdef0123456789"}"#)
            }
            try await Self.run(["1", "--merge"], session: session)
        }

        @Test(arguments: [true, false])
        func readsGraphQLAutoMergeState(enabled: Bool) async throws {
            let session = MockURLProtocol.session()
            MockURLProtocol.handler = { request in
                let state = enabled
                    ? #"{"enabledAt":"2026-10-01T10:00:00Z","mergeMethod":"SQUASH","enabledBy":{"login":"octocat"}}"#
                    : "null"
                return Self.response(request, json: "{\"data\":{\"node\":{\"autoMergeRequest\":\(state)}}}")
            }
            let gql = GraphQLClient(configuration: Configuration(), session: session)
            let payload: AutoMergeStateResponse = try await gql.query(
                """
                query($id: ID!) {
                  node(id: $id) {
                    ... on PullRequest { autoMergeRequest { enabledAt mergeMethod enabledBy { login } } }
                  }
                }
                """, variables: ["id": "PR_node"])
            if enabled {
                let state = try #require(payload.node.autoMergeRequest)
                #expect(state.mergeMethod == "SQUASH")
                #expect(state.enabledBy?.login == "octocat")
                #expect(state.enabledAt == ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z"))
            } else {
                #expect(payload.node.autoMergeRequest == nil)
            }
        }

        private static func run(_ arguments: [String], session: URLSession) async throws {
            let command = try PrMerge.parse(arguments)
            let config = Configuration()
            try await command.run(
                target: RepositoryReference(owner: "cli", name: "cli"),
                api: APIClient(configuration: config, session: session),
                gql: GraphQLClient(configuration: config, session: session))
        }

        private static func body(_ request: URLRequest) throws -> [String: Any] {
            // swift-corelibs-foundation (Linux) does not always hand the body to a URLProtocol.
            let data = try APIClientTests.requestBodyData(from: request)
            if data.isEmpty { return [:] }
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        private static func status(_ status: String, mergeQueueEnabled: Bool = false) -> String {
            let queue = mergeQueueEnabled ? "true" : "false"
            return #"""
                {"data":{"repository":{"pullRequest":{
                  "id":"PR_node","state":"OPEN","mergeStateStatus":"\#(status)",
                  "baseRefName":"main","isMergeQueueEnabled":\#(queue)}}}}
                """#
        }

        private static func response(_ request: URLRequest, json: String) -> (HTTPURLResponse, Data) {
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                             headerFields: ["Content-Type": "application/json"])!, Data(json.utf8))
        }
    }

    private struct AutoMergeStateResponse: Decodable, Sendable {
        let node: AutoMergeStateNode
    }

    private struct AutoMergeStateNode: Decodable, Sendable {
        let autoMergeRequest: GQLAutoMerge?
    }
}
#endif
