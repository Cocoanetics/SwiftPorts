#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import GitLFSTestSupport
import Testing
@testable import GitLFSKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("LFS PUT server comparison", .serialized)
struct LFSPlainUploadTests {
    @Test("1 MB file/Data uploads reach Python with unambiguous framing",
          .timeLimit(.minutes(1)), arguments: ["file", "data"], [false, true])
    func upload(kind: String, expectContinue: Bool) async throws {
        let server = try await LFSPlainUploadServer.start()
        defer { server.stop() }
        let data = try await send(try #require(server.endpoint), kind: kind, expectContinue: expectContinue)
        let receipt = try JSONDecoder().decode(LFSPlainUploadReceipt.self, from: data)
        #expect(receipt.received == 1_000_000)
        #expect(receipt.sha256 == LFSServerRepository.oid(Data(repeating: 0x61, count: 1_000_000)))
        #expect(receipt.headers["content-length"] == "1000000")
        #expect(receipt.headers["transfer-encoding"] == nil)
        #expect(receipt.headers["expect"] == (expectContinue ? "100-continue" : nil))
    }

    @Test("the same platform file/Data transport uploads 1 MB to NIO",
          .timeLimit(.minutes(1)), arguments: ["file", "data"], [false, true])
    func nioUpload(kind: String, expectContinue: Bool) async throws {
        let bytes = Data(repeating: 0x61, count: 1_000_000)
        let oid = LFSServerRepository.oid(bytes)
        try await LFSTestServer.withServer { server in
            let url = server.endpoint.appendingPathComponent("objects/" + oid)
            _ = try await send(url, kind: kind, expectContinue: expectContinue)
            let put = try #require(server.requests().first { $0.method == "PUT" })
            #expect(put.requestBody == bytes)
            #expect(put.requestHeaders["content-length"] == String(bytes.count))
            #expect(put.requestHeaders["transfer-encoding"] == nil)
            #expect(put.requestHeaders["expect"] == (expectContinue ? "100-continue" : nil))
        }
    }

    @Test("redirects retain configured headers and follow the platform method rules", arguments: [303, 307])
    func redirects(code: Int) async throws {
        let server = try await LFSPlainUploadServer.start()
        defer { server.stop() }
        let url = try #require(server.endpoint).appendingPathComponent("redirect\(code)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Basic Z2l0OnNlY3JldA==", forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["X-LFS-Configured": "preserved"]
        let result = try await LFSTransferDelegate(stream: LFSTransferStream()).execute(
            request, body: .data(Data(repeating: 0x61, count: 1_000_000)), configuration: configuration)
        let receipt = try JSONDecoder().decode(LFSPlainUploadReceipt.self, from: result.body)
        #expect(result.status == 200)
        #expect(receipt.method == (code == 303 ? "GET" : "PUT"))
        #expect(receipt.received == (code == 303 ? 0 : 1_000_000))
        #if os(Windows)
        // FoundationNetworking/git-lfs preserve authorization on same-origin
        // redirects. Darwin URLSession instead removes it, even on this origin.
        #expect(receipt.headers["authorization"] == "Basic Z2l0OnNlY3JldA==")
        #endif
        #expect(receipt.headers["x-lfs-configured"] == "preserved")
    }

    #if os(Windows)
    @Test("the upload uses the session's explicit HTTP proxy configuration")
    func configuredProxy() async throws {
        let server = try await LFSPlainUploadServer.start()
        defer { server.stop() }
        let proxy = try #require(server.endpoint)
        var request = URLRequest(url: try #require(URL(string: "http://lfs.invalid/target")))
        request.httpMethod = "PUT"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": try #require(proxy.port),
            "ExceptionsList": [] as [String]
        ]
        let result = try await LFSTransferDelegate(stream: LFSTransferStream()).execute(
            request, body: .data(Data(repeating: 0x61, count: 1_000_000)), configuration: configuration)
        let receipt = try JSONDecoder().decode(LFSPlainUploadReceipt.self, from: result.body)
        #expect(receipt.received == 1_000_000)
        #expect(receipt.headers["host"] == "lfs.invalid")
    }
    #endif

    private func send(_ url: URL, kind: String, expectContinue: Bool) async throws -> Data {
        let bytes = Data(repeating: 0x61, count: 1_000_000)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
        if expectContinue { request.setValue("100-continue", forHTTPHeaderField: "Expect") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        #if os(Windows)
        // Exercise the production workaround, not the known-broken raw
        // URLSession API; the independent server still checks the wire bytes.
        let body: LFSRequestBody = kind == "file" ? .file(file) : .data(bytes)
        let result = try await LFSTransferDelegate(stream: LFSTransferStream()).execute(
            request, body: body, configuration: configuration)
        #expect(result.status == 200)
        return result.body
        #else
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let response: URLResponse
        let data: Data
        if kind == "file" {
            (data, response) = try await session.upload(for: request, fromFile: file)
        } else {
            request.httpBody = bytes
            (data, response) = try await session.data(for: request)
        }
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return data
        #endif
    }
}
#endif
