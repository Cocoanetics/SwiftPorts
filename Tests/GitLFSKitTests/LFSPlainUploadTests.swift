#if os(macOS) || os(Linux) || os(Windows)
import Foundation
import GitLFSTestSupport
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("URLSession PUT server comparison", .serialized)
struct LFSPlainUploadTests {
    @Test("1 MB file/Data uploads reach Python with unambiguous framing",
          .timeLimit(.minutes(1)), arguments: ["file", "data"], [false, true])
    func upload(kind: String, expectContinue: Bool) async throws {
        let server = try await LFSPlainUploadServer.start()
        defer {
            print("Python \(kind)/expect=\(expectContinue):\n\(server.diagnostics())")
            server.stop()
        }
        let data = try await send(try #require(server.endpoint), kind: kind, expectContinue: expectContinue)
        let receipt = try JSONDecoder().decode(LFSPlainUploadReceipt.self, from: data)
        #expect(receipt.received == 1_000_000)
        #expect(receipt.sha256 == LFSServerRepository.oid(Data(repeating: 0x61, count: 1_000_000)))
        #expect(receipt.headers["content-length"] == "1000000")
        #expect(receipt.headers["transfer-encoding"] == nil)
        #expect(receipt.headers["expect"] == (expectContinue ? "100-continue" : nil))
    }

    @Test("the same URLSession file/Data APIs upload 1 MB to NIO",
          .timeLimit(.minutes(1)), arguments: ["file", "data"], [false, true])
    func nioUpload(kind: String, expectContinue: Bool) async throws {
        let bytes = Data(repeating: 0x61, count: 1_000_000)
        let oid = LFSServerRepository.oid(bytes)
        try await LFSTestServer.withServer(trace: {
            print("NIO direct \(kind)/expect=\(expectContinue): \($0)")
        }, { server in
            let url = server.endpoint.appendingPathComponent("objects/" + oid)
            _ = try await send(url, kind: kind, expectContinue: expectContinue)
            let put = try #require(server.requests().first { $0.method == "PUT" })
            #expect(put.requestBody == bytes)
            #expect(put.requestHeaders["content-length"] == String(bytes.count))
            #expect(put.requestHeaders["transfer-encoding"] == nil)
            #expect(put.requestHeaders["expect"] == (expectContinue ? "100-continue" : nil))
        })
    }

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
    }
}
#endif
