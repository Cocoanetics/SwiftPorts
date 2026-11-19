import Foundation
import Testing
import SwiftGit
@testable import GitLFSKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records the requests a batch test's `URLSession` makes. The handler is
/// process-global, so this suite is serialized. State is not the credential
/// suite's `LFSMockURLProtocol`, which tests may run beside this one.
final class LFSBatchURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private static let state = BatchLock<(Handler, [URLRequest])?>(nil)

    static func install(_ handler: @escaping Handler) {
        state.withLock { $0 = (handler, []) }
    }

    static func requests() -> [URLRequest] {
        state.withLock { $0?.1 ?? [] }
    }

    static func reset() { state.withLock { $0 = nil } }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.state.withLock { state -> Handler? in
            guard var current = state else { return nil }
            current.1.append(Self.withBody(request))
            state = current
            return current.0
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLSession` moves `httpBody` onto `httpBodyStream` before the protocol
    /// sees the request. Snapshot the bytes so the test can read `httpBody`.
    private static func withBody(_ request: URLRequest) -> URLRequest {
        var copy = request
        if let body = copy.httpBody, !body.isEmpty { return copy }
        copy.httpBody = bodyData(request)
        return copy
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        var count = stream.read(&buffer, maxLength: buffer.count)
        while count > 0 {
            data.append(contentsOf: buffer.prefix(count))
            count = stream.read(&buffer, maxLength: buffer.count)
        }
        return data
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LFSBatchURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

private final class BatchLock<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class BatchCalls: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
}

@Suite("LFSBatchTests", .serialized)
struct LFSBatchTests {
    private let oid = "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393"
    private let batchURL = "https://example.com/repo.git/info/lfs/objects/batch"
    private let endpointURL = "https://example.com/repo.git/info/lfs"

    private func run(
        config: [(key: String, value: String)] = [("http.extraheader", "X-LFS-Test: alpha")],
        provider: CredentialProvider? = nil,
        _ body: (LFSClient) async throws -> Void
    ) async throws {
        let host = IsolatedLFSHost()
        try await host.run {
            let made = try await LFSFixture.make(
                host, "batch", remotes: [("origin", "https://example.com/repo.git")], config: config)
            let lfs = await LFSClient(
                git: made.client, credentials: provider, configuration: LFSBatchURLProtocol.configuration())
            try await body(lfs)
        }
    }

    private func downloadJSON(size: Int = 12) -> String {
        #"{"operation":"download","objects":[{"oid":"\#(oid)","size":\#(size)}],"ref":{},"hash_algo":"sha256"}"#
    }

    private func text(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    @Test("posts the batch JSON without a transfers field")
    func postsTheBatchJSONWithoutATransfersField() async throws {
        let payload = #"{"transfer":"basic","hash_algo":"sha256","objects":[{"oid":"\#(oid)","size":12}]}"#
        LFSBatchURLProtocol.install { _ in (200, Data(payload.utf8)) }
        defer { LFSBatchURLProtocol.reset() }
        try await run { lfs in
            let response = try await lfs.batch(
                operation: "download", objects: [LFSBatchObject(oid: oid, size: 12)])
            let requests = LFSBatchURLProtocol.requests()
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString == batchURL)
            #expect(request.value(forHTTPHeaderField: "Accept") == LFSMediaType.json)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == LFSMediaType.requestContentType)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "git-lfs")
            #expect(request.value(forHTTPHeaderField: "X-LFS-Test") == "alpha")
            let body = text(request)
            #expect(body == downloadJSON())
            #expect(!body.contains("\"transfers\""))
            #expect(!body.contains("\"name\""))
            #expect(!body.contains("\"path\""))
            #expect(!body.contains("\"authenticated\""))
            #expect(!body.contains("\"actions\""))
            #expect(!body.contains("\"error\""))
            #expect(response.transfer == "basic")
            #expect(response.hashAlgorithm == "sha256")
            #expect(response.endpoint.url == endpointURL)
            #expect(response.objects == [LFSBatchObject(oid: oid, size: 12)])
        }
    }

    @Test("a named ref, name and path are sent, and transfers stays omitted")
    func namedRefAndPath() async throws {
        LFSBatchURLProtocol.install { _ in (200, Data(#"{"objects":[]}"#.utf8)) }
        defer { LFSBatchURLProtocol.reset() }
        try await run { lfs in
            let object = LFSBatchObject(oid: oid, size: 4, name: "blob.bin", path: "dir/blob.bin")
            _ = try await lfs.batch(
                operation: "upload", objects: [object], ref: LFSBatchRef(name: "refs/heads/main"))
            let body = text(try #require(LFSBatchURLProtocol.requests().first))
            let expected = "{\"operation\":\"upload\",\"objects\":[{\"name\":\"blob.bin\",\"oid\":\"\(oid)\","
                + "\"size\":4,\"path\":\"dir/blob.bin\"}],\"ref\":{\"name\":\"refs/heads/main\"},"
                + "\"hash_algo\":\"sha256\"}"
            #expect(body == expected)
            #expect(!body.contains("\"transfers\""))
        }
    }

    @Test("lfs.basictransfersonly uses the same basic list and omits transfers")
    func basicTransfersOnly() async throws {
        LFSBatchURLProtocol.install { _ in (200, Data(#"{"objects":[]}"#.utf8)) }
        defer { LFSBatchURLProtocol.reset() }
        try await run(config: [
            ("http.extraheader", "X-LFS-Test: alpha"),
            ("lfs.basictransfersonly", "true")
        ]) { lfs in
            _ = try await lfs.batch(operation: "download", objects: [LFSBatchObject(oid: oid, size: 12)])
            #expect(text(try #require(LFSBatchURLProtocol.requests().first)) == downloadJSON())
        }
    }

    @Test("transfers is sent only when the adapter list is not exactly [basic]")
    func transfersWhenNotOnlyBasic() {
        let object = LFSBatchObject(oid: "abc", size: 1)
        let basic = LFSBatchEncoding.data(
            operation: "download", objects: [object], transfers: ["basic"], ref: LFSBatchRef())
        #expect(!String(decoding: basic, as: UTF8.self).contains("transfers"))
        var marked = object
        marked.authenticated = true
        let extra = LFSBatchEncoding.data(
            operation: "download", objects: [marked], transfers: ["basic", "custom"], ref: LFSBatchRef())
        let text = String(decoding: extra, as: UTF8.self)
        let head = #"{"operation":"download","objects":[{"oid":"abc","size":1,"authenticated":true}],"#
        let tail = #""transfers":["basic","custom"],"ref":{},"hash_algo":"sha256"}"#
        #expect(text == head + tail)
    }

    @Test("a per-object error keeps the server message")
    func objectError() async throws {
        let payload = """
        {"objects":[{"oid":"abc","size":1,"error":{"code":404,"message":"Object does not exist"}}]}
        """
        LFSBatchURLProtocol.install { _ in (200, Data(payload.utf8)) }
        defer { LFSBatchURLProtocol.reset() }
        try await run { lfs in
            let response = try await lfs.batch(
                operation: "download", objects: [LFSBatchObject(oid: "abc", size: 1)])
            let object = try #require(response.objects.first)
            #expect(object.error?.code == 404)
            #expect(object.error?.message == "Object does not exist")
            let wrapped = "[abc] Object does not exist: [404] Object does not exist"
            #expect(object.errorText == wrapped)
            #expect(LFSBatchURLProtocol.requests().count == 1)
        }
    }

    @Test("a hash_algo other than sha256 is rejected")
    func rejectsHashAlgorithm() async throws {
        LFSBatchURLProtocol.install { _ in (200, Data(#"{"hash_algo":"sha512","objects":[]}"#.utf8)) }
        defer { LFSBatchURLProtocol.reset() }
        try await run { lfs in
            do {
                _ = try await lfs.batch(operation: "download", objects: [LFSBatchObject(oid: oid, size: 1)])
                Issue.record("expected an unsupported hash algorithm")
            } catch let error as LFSClientError {
                #expect(error.description == "batch response: unsupported hash algorithm: \"sha512\"")
            }
        }
    }

    @Test("a 2xx other than 200 is an invalid status")
    func rejectsCreated() async throws {
        LFSBatchURLProtocol.install { _ in (201, Data(#"{"hash_algo":"sha256","objects":[]}"#.utf8)) }
        defer { LFSBatchURLProtocol.reset() }
        try await run { lfs in
            do {
                _ = try await lfs.batch(operation: "download", objects: [LFSBatchObject(oid: oid, size: 1)])
                Issue.record("expected status 201 to fail")
            } catch let error as LFSClientError {
                #expect(error.description == "Invalid HTTP status for POST \(batchURL): 201")
            }
        }
    }

    @Test("statuses 422, 501, 507 and 509 use git-lfs text, unless JSON has a message")
    func statusText() async throws {
        let cases = [
            (422, "Unprocessable entity"),
            (501, "Not Implemented"),
            (507, "Insufficient server storage"),
            (509, "Bandwidth limit exceeded")
        ]
        try await run { lfs in
            for (status, prefix) in cases {
                LFSBatchURLProtocol.install { _ in (status, Data()) }
                do {
                    _ = try await lfs.batch(operation: "download", objects: [LFSBatchObject(oid: oid, size: 1)])
                    Issue.record("expected HTTP \(status) to fail")
                } catch let error as LFSClientError {
                    #expect(error.description == "\(prefix): \(batchURL)")
                }
            }
            LFSBatchURLProtocol.install { _ in (422, Data(#"{"message":"nope"}"#.utf8)) }
            defer { LFSBatchURLProtocol.reset() }
            do {
                _ = try await lfs.batch(operation: "download", objects: [LFSBatchObject(oid: oid, size: 1)])
                Issue.record("expected the JSON message")
            } catch let error as LFSClientError {
                #expect(error.description == "nope")
            }
        }
    }

    @Test("an action expiring within 5 seconds is posted again")
    func retriesWhenTheActionExpiresWithinFiveSeconds() async throws {
        let calls = BatchCalls()
        let expired = """
        {"transfer":"basic","objects":[{"oid":"\(oid)","size":12,"actions":{"download":{
        "href":"https://cdn.example/old","expires_at":"2099-01-01T00:00:00Z","expires_in":1}}}]}
        """
        let fresh = """
        {"transfer":"basic","objects":[{"oid":"\(oid)","size":12,"authenticated":true,
        "actions":{"download":{"href":"https://cdn.example/new","header":{"Authorization":"Bearer t"},
        "expires_at":"2000-01-01T00:00:00Z","expires_in":3600}},
        "_links":{"verify":{"href":"https://cdn.example/verify"}}}]}
        """
        LFSBatchURLProtocol.install { _ in
            calls.record()
            let body = calls.count == 1 ? expired : fresh
            return (200, Data(body.utf8))
        }
        defer { LFSBatchURLProtocol.reset() }
        try await run { lfs in
            let response = try await lfs.batch(
                operation: "download", objects: [LFSBatchObject(oid: oid, size: 12)])
            let requests = LFSBatchURLProtocol.requests()
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { text($0) == downloadJSON() })
            let object = try #require(response.objects.first)
            #expect(object.authenticated)
            let action = try #require(object.actions["download"])
            #expect(action.href == "https://cdn.example/new")
            #expect(action.header["Authorization"] == "Bearer t")
            #expect(action.expiresIn == 3600)
            #expect(action.expiresAt != nil)
            #expect(!action.isExpired())
            #expect(action.requestedAt.timeIntervalSinceNow > -120)
            #expect(object.links["verify"]?.href == "https://cdn.example/verify")
        }
    }

    @Test("expires_at in the past is re-batched when expires_in is absent")
    func retriesWhenExpiresAtIsPast() async throws {
        let calls = BatchCalls()
        let expired = """
        {"objects":[{"oid":"\(oid)","size":12,"actions":{"download":{
        "href":"https://cdn.example/old","expires_at":"2000-01-01T00:00:00Z"}}}]}
        """
        let fresh = """
        {"objects":[{"oid":"\(oid)","size":12,"actions":{"download":{
        "href":"https://cdn.example/new"}}}]}
        """
        LFSBatchURLProtocol.install { _ in
            calls.record()
            return (200, Data((calls.count == 1 ? expired : fresh).utf8))
        }
        defer { LFSBatchURLProtocol.reset() }
        try await run { lfs in
            let response = try await lfs.batch(
                operation: "download", objects: [LFSBatchObject(oid: oid, size: 12)])
            #expect(LFSBatchURLProtocol.requests().count == 2)
            let action = try #require(response.objects.first?.actions["download"])
            #expect(action.href == "https://cdn.example/new")
            #expect(!action.isExpired())
        }
    }

    @Test("an empty object list does not POST")
    func emptyBatchSkipsTheNetwork() async throws {
        LFSBatchURLProtocol.install { _ in (500, Data(#"{"message":"no"}"#.utf8)) }
        defer { LFSBatchURLProtocol.reset() }
        try await run { lfs in
            let response = try await lfs.batch(operation: "download", objects: [])
            #expect(response.objects.isEmpty)
            #expect(LFSBatchURLProtocol.requests().isEmpty)
        }
    }

    @Test("a 401 on the batch is retried with credentials")
    func retriesUnauthorized() async throws {
        let calls = BatchCalls()
        let wanted = LFSBasicAuth.header(username: "git", password: "secret")
        LFSBatchURLProtocol.install { request in
            let ok = request.value(forHTTPHeaderField: "Authorization") == wanted
            let body = ok ? Data(#"{"objects":[]}"#.utf8) : Data(#"{"message":"nope"}"#.utf8)
            return (ok ? 200 : 401, body)
        }
        defer { LFSBatchURLProtocol.reset() }
        let provider: CredentialProvider = { _, _, allowed in
            guard allowed.contains(.userPassword) else { return nil }
            calls.record()
            return .userPassword(username: "git", password: "secret")
        }
        try await run(provider: provider) { lfs in
            _ = try await lfs.batch(operation: "download", objects: [LFSBatchObject(oid: oid, size: 1)])
            #expect(calls.count == 1)
            let requests = LFSBatchURLProtocol.requests()
            #expect(requests.count == 2)
            #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
            #expect(requests[1].value(forHTTPHeaderField: "Authorization") == wanted)
            #expect(requests[0].value(forHTTPHeaderField: "Accept") == LFSMediaType.json)
            #expect(requests[1].value(forHTTPHeaderField: "User-Agent") == "git-lfs")
        }
    }

    @Test("batchURL appends the path and keeps an endpoint query")
    func batchURLKeepsTheQuery() {
        let cases = [
            ("https://host/info/lfs?token=x", "https://host/info/lfs/objects/batch?token=x"),
            ("https://host/info/lfs/?token=x", "https://host/info/lfs/objects/batch?token=x"),
            ("https://example.com/repo.git/info/lfs", "https://example.com/repo.git/info/lfs/objects/batch"),
            ("https://example.com/repo.git/info/lfs/", "https://example.com/repo.git/info/lfs/objects/batch"),
            ("https://user:secret@host/info/lfs?token=a%2Fb",
             "https://user:secret@host/info/lfs/objects/batch?token=a%2Fb")
        ]
        for (endpoint, expected) in cases {
            #expect(LFSClient.batchURL(endpoint)?.absoluteString == expected)
        }
    }

    @Test("a configured endpoint query is still a query on the batch POST")
    func postsBatchWithEndpointQuery() async throws {
        let endpoint = "https://example.com/repo.git/info/lfs?token=x"
        let expected = "https://example.com/repo.git/info/lfs/objects/batch?token=x"
        LFSBatchURLProtocol.install { _ in (200, Data(#"{"objects":[]}"#.utf8)) }
        defer { LFSBatchURLProtocol.reset() }
        try await run(config: [
            ("http.extraheader", "X-LFS-Test: alpha"),
            ("lfs.url", endpoint)
        ]) { lfs in
            let response = try await lfs.batch(
                operation: "download", objects: [LFSBatchObject(oid: oid, size: 1)])
            let request = try #require(LFSBatchURLProtocol.requests().first)
            #expect(request.url?.absoluteString == expected)
            #expect(response.endpoint.url == endpoint)
        }
    }
}
