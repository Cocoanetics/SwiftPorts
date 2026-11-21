#if os(Windows)
import Foundation
import FoundationNetworking
import GitLFSTestSupport
import Testing
import WinSDK
@testable import GitLFSKit

@Suite("LFS curl file uploads", .timeLimit(.minutes(1)))
struct LFSCurlUploadTests {
    @Test("native file readers keep independent offsets and allow shared writes and deletion")
    func fileReaders() throws {
        let bytes = Data((0..<1_000_000).map { UInt8($0 / (64 * 1024)) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LFS reader é \(UUID().uuidString)")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try LFSCurlFile(url: url)
        let second = try LFSCurlFile(url: url)
        #expect(first.length == Int64(bytes.count))
        #expect(try read(first) == bytes.prefix(64 * 1024))
        #expect(try read(second) == bytes.prefix(64 * 1024))
        try first.seek(to: Int64(bytes.count))
        #expect(try read(first).isEmpty)
        try second.seek(to: 3)
        for offset: Int64 in [-1, Int64(bytes.count) + 1, Int64.max] {
            #expect(throws: URLError.self) { try second.seek(to: offset) }
        }
        #expect(try read(second) == bytes.subdata(in: 3..<(3 + 64 * 1024)))
        #expect(try read(first).isEmpty)
        let writer = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
                        nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        let handle = try #require(writer)
        #expect(handle != INVALID_HANDLE_VALUE)
        if handle != INVALID_HANDLE_VALUE { CloseHandle(handle) }
        try FileManager.default.removeItem(at: url)
        try first.seek(to: 0)
        #expect(try read(first) == bytes.prefix(64 * 1024))
        #expect(throws: URLError.self) { _ = try LFSCurlFile(url: url) }
    }

    private func read(_ file: LFSCurlFile) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        let amount = try buffer.withUnsafeMutableBufferPointer {
            try file.read(try #require($0.baseAddress), count: $0.count)
        }
        return Data(buffer.prefix(amount))
    }

    @Test("concurrent file uploads open independent bounded readers", arguments: [0, 1_000_000])
    func concurrentFileUploads(size: Int) async throws {
        let bytes = Data(repeating: 0x61, count: size)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("LFS upload é \(UUID().uuidString)")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await LFSTestServer.withServer { server in
            // The fixture answers its first upload immediately, then holds four.
            await server.holdObjectTransfers(untilInFlight: 4, timeout: .seconds(3))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<5 {
                    let url = server.endpoint.appendingPathComponent("objects/concurrent-\(index)")
                    group.addTask {
                        var request = URLRequest(url: url)
                        request.httpMethod = "PUT"
                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.connectionProxyDictionary = ["HTTPEnable": 0]
                        configuration.timeoutIntervalForRequest = 5
                        configuration.timeoutIntervalForResource = 10
                        let deltas = TransferTestLock<[Int64]>([])
                        let transport = LFSCurlUpload(stream: LFSTransferStream(progress: { _, delta in
                            deltas.withLock { $0.append(delta) }
                        }))
                        let result = try await transport.execute(
                            request, body: .file(file), configuration: configuration)
                        #expect(result.status == 200)
                        #expect(deltas.withLock { $0.reduce(0, +) } == Int64(size))
                        #expect(deltas.withLock { $0.allSatisfy { $0 > 0 && $0 <= 64 * 1024 } })
                    }
                }
                try await group.waitForAll()
            }
            #expect(await server.peakObjectTransfers() >= 4)
            let puts = server.requests().filter { $0.method == "PUT" }
            #expect(puts.count == 5)
            for put in puts {
                #expect(put.requestBody == bytes)
                #expect(put.requestHeaders["content-length"] == String(size))
                #expect(put.requestHeaders["transfer-encoding"] == nil)
            }
        }
    }

    @Test("a 307 redirect rewinds curl progress and takes back sent bytes", arguments: ["file", "data"])
    func redirectRewind(kind: String) async throws {
        let bytes = Data(repeating: 0x62, count: 200_000)
        let oid = LFSServerRepository.oid(bytes)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("LFS rewind \(UUID().uuidString)")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try await LFSTestServer.withServer { server in
            let url = server.endpoint.appendingPathComponent("objects/\(oid)")
            server.inject(.putRedirect(oid: oid, code: 307, location: url.absoluteString))
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(String(bytes.count), forHTTPHeaderField: "Content-Length")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = ["HTTPEnable": 0]
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 10
            let sent = LFSSentBytes()
            let deltas = TransferTestLock<[Int64]>([])
            let totals = TransferTestLock<[Int64]>([])
            let transport = LFSCurlUpload(stream: LFSTransferStream(progress: { _, delta in
                sent.record(delta: delta)
                deltas.withLock { $0.append(delta) }
                totals.withLock { $0.append(sent.total) }
            }))
            let body: LFSRequestBody = kind == "file" ? .file(file) : .data(bytes)
            let result = try await transport.execute(request, body: body, configuration: configuration)
            #expect(result.status == 200)
            let puts = server.requests().filter { $0.method == "PUT" }
            #expect(puts.map(\.status) == [307, 200])
            #expect(server.bytes(for: oid) == bytes)
            #expect(deltas.withLock { $0.contains { $0 < 0 } })
            #expect(deltas.withLock { $0.reduce(0, +) } == Int64(bytes.count))
            #expect(totals.withLock { $0.contains(0) })
            #expect(sent.total == Int64(bytes.count))
        }
    }
}
#endif
