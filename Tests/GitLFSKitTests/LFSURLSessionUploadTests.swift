#if os(Windows) || os(macOS) || os(Linux)
import Foundation
import GitLFSTestSupport
import Testing
@testable import GitLFSKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("LFS platform upload transport")
struct LFSURLSessionUploadTests {
    @Test("1 MB uploads preserve framing, progress and HTTP errors",
          .timeLimit(.minutes(1)), arguments: ["file", "data", "stream"], [200, 503, 401])
    func upload(kind: String, status: Int) async throws {
        let bytes = Data(repeating: 0x61, count: 1_000_000)
        let oid = LFSServerRepository.oid(bytes)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await LFSTestServer.withServer { server in
            if status != 200 { server.inject(.putStatus(oid: oid, code: status)) }
            let url = try #require(URL(string: server.endpoint.absoluteString + "/objects/" + oid))
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            let body: LFSRequestBody
            switch kind {
            case "file":
                body = .file(file)
                request.setValue("100-continue", forHTTPHeaderField: "Expect")
            case "stream": body = .stream(try #require(InputStream(url: file)))
            default: body = .data(bytes)
            }
            if kind == "stream" { request.setValue("chunked", forHTTPHeaderField: "Transfer-Encoding") }
            else { request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length") }
            let deltas = TransferTestLock<[Int64]>([])
            let success = TransferTestLock(0)
            let transport = LFSTransferDelegate(stream: LFSTransferStream(progress: { _, delta in
                deltas.withLock { $0.append(delta) }
            }, success: { success.withLock { $0 += 1 } }))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            let result = try await transport.execute(request, body: body, configuration: configuration)
            #expect(result.status == status)
            #expect(result.accepted == (status == 200))
            #expect(success.withLock { $0 } == (status == 200 ? 1 : 0))
            let progress = deltas.withLock { $0 }
            #expect(progress.reduce(0, +) == Int64(bytes.count))
            #expect(progress.allSatisfy { $0 > 0 })
            let put = try #require(server.requests().first { $0.method == "PUT" })
            #expect(put.requestBody == bytes)
            if kind == "stream" {
                #expect(put.requestHeaders["content-length"] == nil)
                #expect(put.requestHeaders["transfer-encoding"] == "chunked")
            } else {
                #expect(put.requestHeaders["content-length"] == String(bytes.count))
                #expect(put.requestHeaders["transfer-encoding"] == nil)
            }
        }
    }

    @Test("cancellation interrupts an upload waiting for its response", .timeLimit(.minutes(1)))
    func cancelWaitingForResponse() async throws {
        try await LFSTestServer.withServer { server in
            await server.holdObjectTransfers(untilInFlight: 2, timeout: .seconds(10))
            let url = try #require(URL(string: server.endpoint.absoluteString + "/objects/test"))
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            _ = try await LFSTransferDelegate(stream: LFSTransferStream()).execute(
                request, body: .data(Data()), configuration: .ephemeral)
            let pending = Task {
                try await LFSTransferDelegate(stream: LFSTransferStream()).execute(
                    request, body: .data(Data(repeating: 0x61, count: 1_000_000)), configuration: .ephemeral)
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while await server.peakObjectTransfers() == 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(await server.peakObjectTransfers() == 1)
            pending.cancel()
            await #expect {
                try await pending.value
            } throws: { error in
                (error as? URLError)?.code == .cancelled
            }
        }
    }

    @Test("idle timeout interrupts an upload waiting for its response", .timeLimit(.minutes(1)))
    func responseTimeout() async throws {
        try await LFSTestServer.withServer { server in
            await server.holdObjectTransfers(untilInFlight: 2, timeout: .seconds(10))
            let url = try #require(URL(string: server.endpoint.absoluteString + "/objects/test"))
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            let configuration = URLSessionConfiguration.ephemeral
            _ = try await LFSTransferDelegate(stream: LFSTransferStream()).execute(
                request, body: .data(Data()), configuration: configuration)
            configuration.timeoutIntervalForRequest = 0.2
            configuration.timeoutIntervalForResource = 10
            let sent = TransferTestLock<Int64>(0)
            await #expect {
                _ = try await LFSTransferDelegate(stream: LFSTransferStream(progress: { _, delta in
                    sent.withLock { $0 += delta }
                })).execute(
                    request, body: .data(Data(repeating: 0x61, count: 1_000_000)), configuration: configuration)
            } throws: { error in
                (error as? URLError)?.code == .timedOut
            }
            #expect(sent.withLock { $0 } == 1_000_000)
            #expect(await server.peakObjectTransfers() == 1)
        }
    }
}
#endif
