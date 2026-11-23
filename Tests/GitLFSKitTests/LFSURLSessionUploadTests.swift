#if os(Windows) || os(macOS) || os(Linux)
import Foundation
import GitLFSTestSupport
import Testing
@testable import GitLFSKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("LFS platform upload transport", .timeLimit(.minutes(2)))
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
            #if os(Windows)
            #expect(progress.reduce(0, +) == Int64(bytes.count))
            #else
            // A fast local URLSession upload can finish without a progress
            // callback. The basic adapter reports that remainder on success;
            // this direct probe checks all received bytes separately below.
            #expect(progress.reduce(0, +) <= Int64(bytes.count))
            #endif
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
            _ = try await LFSTransferDelegate(stream: LFSTransferStream()).execute(
                request, body: .data(Data()), configuration: .ephemeral)
            let bytes = Data(repeating: 0x61, count: 1_000_000)
            let sent = TransferTestLock<Int64>(0)
            let receipts = server.heldObjectRequests()
            try await withThrowingTaskGroup(of: LFSUploadTimeoutEvent.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    var iterator = receipts.makeAsyncIterator()
                    guard let receipt = await iterator.next() else { return .missingReceipt }
                    return .receipt(receipt)
                }
                group.addTask { [request] in
                    let configuration = URLSessionConfiguration.ephemeral
                    // #283: Linux FoundationNetworking converts Int(seconds) * 1000,
                    // so fractional seconds collapse to a roughly 1 ms timer.
                    configuration.timeoutIntervalForRequest = 2
                    configuration.timeoutIntervalForResource = 10
                    do {
                        _ = try await LFSTransferDelegate(stream: LFSTransferStream(progress: { _, delta in
                            sent.withLock { $0 += delta }
                        })).execute(request, body: .data(bytes), configuration: configuration)
                        return .completed(.success(()), at: ContinuousClock.now)
                    } catch {
                        return .completed(.failure(error), at: ContinuousClock.now)
                    }
                }
                group.addTask {
                    // Bound missing arrival or completion before the hold's
                    // ten-second auto-release could answer the request.
                    try await Task.sleep(for: .seconds(8))
                    return .deadline
                }
                // Task-group delivery order need not match event order; collect
                // both and compare the timestamps taken where each happened.
                var receipt: LFSHeldObjectRequest?
                var completion: (result: Result<Void, any Error>, at: ContinuousClock.Instant)?
                events: while receipt == nil || completion == nil, let event = try await group.next() {
                    switch event {
                    case .receipt(let value): receipt = value
                    case .completed(let result, let at): completion = (result, at)
                    case .missingReceipt, .deadline: break events
                    }
                }
                guard let receipt, let completion else {
                    Issue.record("""
                        gate ended without both a parked-response receipt and upload completion: \
                        receipt \(receipt != nil), completion \(completion != nil)
                        """)
                    return
                }
                #expect(receipt.method == "PUT")
                #expect(receipt.path == "/objects/test")
                #expect(receipt.requestBody == bytes)
                try #require(receipt.responseIsHeld)
                #expect(receipt.receivedAt < completion.at)
                #expect {
                    try completion.result.get()
                } throws: { error in
                    (error as? URLError)?.code == .timedOut
                }
            }
            #expect(sent.withLock { $0 } == 1_000_000)
            #expect(await server.peakObjectTransfers() == 1)
        }
    }
}
#endif
