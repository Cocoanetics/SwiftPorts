import Foundation
import Testing
import SwiftGit
import ShellKit
@testable import GitLFSKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records the requests a credential test's `URLSession` makes. The handler
/// is process-global, so this suite is serialized.
final class LFSMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private static let state = TestBox<(Handler, [URLRequest])?>(nil)

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
            current.1.append(request)
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

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LFSMockURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}

private final class TestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class CredentialCalls: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
}

@Suite("LFS credentials", .serialized)
struct LFSCredentialTests {
    let host = IsolatedLFSHost()
    private let batch = URL(string: "https://example.com/repo.git/info/lfs/objects/batch")!

    private func client(
        remote: String = "https://example.com/repo.git",
        config: [(key: String, value: String)] = [("http.extraheader", "X-LFS-Test: alpha")],
        netrc: String? = nil,
        provider: CredentialProvider? = nil
    ) async throws -> (GitClient, LFSClient) {
        if let netrc {
            try Data(netrc.utf8).write(to: host.home.appendingPathComponent(".netrc"))
        }
        let made = try await LFSFixture.make(host, "cred", remotes: [("origin", remote)], config: config)
        let lfs = await LFSClient(git: made.client, credentials: provider, session: LFSMockURLProtocol.session())
        return (made.client, lfs)
    }

    private func provider(_ calls: CredentialCalls, password: String = "from-provider") -> CredentialProvider {
        { _, _, allowed in
            guard allowed.contains(.userPassword) else { return nil }
            calls.record()
            return .userPassword(username: "git", password: password)
        }
    }

    private func get() -> URLRequest {
        var request = URLRequest(url: batch)
        request.httpMethod = "GET"
        return request
    }

    @Test("a 401 with access none retries once with the provider and records basic")
    func retriesAfterUnauthorized() async throws {
        let calls = CredentialCalls()
        let wanted = LFSBasicAuth.header(username: "git", password: "from-provider")
        LFSMockURLProtocol.install { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == wanted ? 200 : 401
            return (status, Data("{\"message\":\"nope\"}".utf8))
        }
        defer { LFSMockURLProtocol.reset() }
        try await host.run {
            let (git, lfs) = try await client(provider: provider(calls))
            let body = try await lfs.data(for: get())
            #expect(body == Data("{\"message\":\"nope\"}".utf8))
            #expect(calls.count == 1)
            let requests = LFSMockURLProtocol.requests()
            #expect(requests.count == 2)
            #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
            #expect(requests[0].value(forHTTPHeaderField: "X-LFS-Test") == "alpha")
            #expect(requests[0].value(forHTTPHeaderField: "User-Agent") == "git-lfs")
            #expect(requests[1].value(forHTTPHeaderField: "Authorization") == wanted)
            #expect(requests[1].value(forHTTPHeaderField: "X-LFS-Test") == "alpha")
            let key = "lfs.https://example.com/repo.git/info/lfs.access"
            #expect(try await git.configGet(key) == "basic")
        }
    }

    @Test("basic access asks on the first request")
    func basicFromTheStart() async throws {
        let calls = CredentialCalls()
        let wanted = LFSBasicAuth.header(username: "git", password: "from-provider")
        LFSMockURLProtocol.install { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == wanted ? 200 : 401
            return (status, Data())
        }
        defer { LFSMockURLProtocol.reset() }
        try await host.run {
            let url = "https://example.com/repo.git/info/lfs"
            let (_, lfs) = try await client(
                config: [("lfs.\(url).access", "basic")],
                provider: provider(calls))
            _ = try await lfs.data(for: get())
            #expect(calls.count == 1)
            #expect(LFSMockURLProtocol.requests().count == 1)
            #expect(LFSMockURLProtocol.requests()[0].value(forHTTPHeaderField: "Authorization") == wanted)
        }
    }

    @Test("a password in the remote URL is used instead of netrc or the provider")
    func embeddedPassword() async throws {
        let calls = CredentialCalls()
        let wanted = LFSBasicAuth.header(username: "git", password: "secret")
        LFSMockURLProtocol.install { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == wanted ? 200 : 401
            return (status, Data("{\"message\":\"nope\"}".utf8))
        }
        defer { LFSMockURLProtocol.reset() }
        try await host.run {
            let netrc = "machine example.com\nlogin git\npassword from-netrc\n"
            let (_, lfs) = try await client(
                remote: "https://git:secret@example.com/repo.git",
                netrc: netrc,
                provider: provider(calls))
            _ = try await lfs.data(for: get())
            #expect(calls.count == 0)
            let requests = LFSMockURLProtocol.requests()
            #expect(requests.count == 2)
            #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
            #expect(requests[1].value(forHTTPHeaderField: "Authorization") == wanted)
        }
    }

    @Test("netrc matches the host without its port and is skipped after a reject")
    func netrcThenProvider() async throws {
        let calls = CredentialCalls()
        let netrcHeader = LFSBasicAuth.header(username: "git", password: "from-netrc")
        let providerHeader = LFSBasicAuth.header(username: "git", password: "from-provider")
        LFSMockURLProtocol.install { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            let status = authorization == providerHeader ? 200 : 401
            return (status, Data())
        }
        defer { LFSMockURLProtocol.reset() }
        try await host.run {
            let netrc = "machine example.com\nlogin git\npassword from-netrc\n"
            let (_, lfs) = try await client(
                remote: "https://example.com:8443/repo.git",
                netrc: netrc,
                provider: provider(calls))
            let batch = URL(string: "https://example.com:8443/repo.git/info/lfs/objects/batch")!
            _ = try await lfs.data(for: URLRequest(url: batch))
            #expect(calls.count == 1)
            let requests = LFSMockURLProtocol.requests()
            #expect(requests.count == 3)
            #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
            #expect(requests[1].value(forHTTPHeaderField: "Authorization") == netrcHeader)
            #expect(requests[2].value(forHTTPHeaderField: "Authorization") == providerHeader)
        }
    }

    @Test("an approved credential is reused and not asked for again")
    func cache() async throws {
        let calls = CredentialCalls()
        let wanted = LFSBasicAuth.header(username: "git", password: "from-provider")
        LFSMockURLProtocol.install { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == wanted ? 200 : 401
            return (status, Data("ok".utf8))
        }
        defer { LFSMockURLProtocol.reset() }
        try await host.run {
            let (_, lfs) = try await client(provider: provider(calls))
            _ = try await lfs.data(for: get())
            _ = try await lfs.data(for: get())
            #expect(calls.count == 1)
            let requests = LFSMockURLProtocol.requests()
            #expect(requests.count == 3)
            #expect(requests[2].value(forHTTPHeaderField: "Authorization") == wanted)
        }
    }

    @Test("an embedded credential that is rejected is not retried")
    func embeddedStops() async throws {
        LFSMockURLProtocol.install { _ in (401, Data("{\"message\":\"nope\"}".utf8)) }
        defer { LFSMockURLProtocol.reset() }
        try await host.run {
            let calls = CredentialCalls()
            let (_, lfs) = try await client(
                remote: "https://git:secret@example.com/repo.git",
                config: [("lfs.https://example.com/repo.git/info/lfs.access", "basic")],
                provider: provider(calls))
            do {
                _ = try await lfs.data(for: get())
                Issue.record("expected the embedded credential to stop the retry")
            } catch let error as LFSClientError {
                #expect(error.description == "Authentication required: nope")
            }
            #expect(calls.count == 0)
            #expect(LFSMockURLProtocol.requests().count == 1)
        }
    }

    @Test("a denied netrc file is not sent")
    func deniedNetrc() async throws {
        let calls = CredentialCalls()
        let providerHeader = LFSBasicAuth.header(username: "git", password: "from-provider")
        LFSMockURLProtocol.install { request in
            let status = request.value(forHTTPHeaderField: "Authorization") == providerHeader ? 200 : 401
            return (status, Data())
        }
        defer { LFSMockURLProtocol.reset() }
        let directory = try await host.run {
            let netrc = "machine example.com\nlogin git\npassword from-netrc\n"
            try Data(netrc.utf8).write(to: host.home.appendingPathComponent(".netrc"))
            let made = try await LFSFixture.make(
                host, "netrc-deny",
                remotes: [("origin", "https://example.com/repo.git")],
                config: [("lfs.https://example.com/repo.git/info/lfs.access", "basic")])
            return made.directory
        }
        let shell = Shell(
            environment: Environment(variables: host.variables, workingDirectory: host.root.path),
            sandbox: host.sandbox { $0.lastPathComponent == ".netrc" || $0.lastPathComponent == "_netrc" })
        try await shell.withCurrent {
            let lfs = await LFSClient(
                git: GitClient(workingDirectory: directory),
                credentials: provider(calls),
                session: LFSMockURLProtocol.session())
            _ = try await lfs.data(for: get())
        }
        #expect(calls.count == 1)
        let requests = LFSMockURLProtocol.requests()
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == providerHeader)
    }

    @Test("data(for:) uploads httpBody and httpBodyStream")
    func uploadsRequestBody() async throws {
        let payload = Data("{\"operation\":\"download\"}".utf8)
        let seen = TestBox([Data]())
        LFSMockURLProtocol.install { request in
            seen.withLock { $0.append(Self.bytes(request)) }
            return (200, Data("{}".utf8))
        }
        defer { LFSMockURLProtocol.reset() }
        try await host.run {
            let (_, lfs) = try await client()
            var streamed = URLRequest(url: batch)
            streamed.httpMethod = "POST"
            streamed.httpBodyStream = InputStream(data: payload)
            #expect(try await lfs.data(for: streamed) == Data("{}".utf8))
            var buffered = URLRequest(url: batch)
            buffered.httpMethod = "POST"
            buffered.httpBody = payload
            #expect(try await lfs.data(for: buffered) == Data("{}".utf8))
        }
        #expect(seen.withLock { $0 } == [payload, payload])
    }

    private static func bytes(_ request: URLRequest) -> Data {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
