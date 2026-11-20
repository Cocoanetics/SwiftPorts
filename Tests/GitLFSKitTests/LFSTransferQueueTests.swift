import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GitLFSTestSupport
import HTTPTypes
import SwiftGit
import Testing
@testable import GitLFSKit

@Suite("LFS basic transfer queue", .serialized)
struct LFSTransferQueueTests {
    let data = Data("hello world\n".utf8)
    var oid: String { hash(data) }

    func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func run(
        config: [(String, String)] = [],
        provider: CredentialProvider? = nil,
        sessionConfiguration: URLSessionConfiguration = LFSTransferURLProtocol.configuration,
        _ body: (LFSClient, LocalStore, URL) async throws -> Void
    ) async throws {
        defer { LFSTransferURLProtocol.reset() }
        let host = IsolatedLFSHost()
        try await host.run {
            let made = try await LFSFixture.make(host, "transfer",
                remotes: [("origin", "https://example.com/repo.git")], config: config)
            let client = await LFSClient(git: made.client, credentials: provider,
                                         configuration: sessionConfiguration)
            try await body(client, LocalStore(gitStorageDirectory: made.directory.appendingPathComponent(".git")),
                           made.directory)
        }
    }

    func queue(
        _ client: LFSClient, _ store: LocalStore, _ direction: LFSTransferDirection = .download,
        clock: LFSTransferClock = LFSTransferClock()
    ) -> LFSTransferQueue {
        LFSTransferQueue(client: client, store: store, direction: direction, remote: "", refName: "refs/heads/main",
                         environment: clock.environment)
    }

    func part(_ store: LocalStore, prefix: Data) async throws -> URL {
        try await LocalStore.makeDirectory(store.incompleteDirectory)
        let file = store.incompleteDirectory.appendingPathComponent(oid + ".part")
        try prefix.write(to: file)
        return file
    }

    @Test("a corrupt download is rejected with the OID mismatch text, is not stored, and leaves the .part file")
    func corruptDownload() async throws {
        let corrupt = Data("corrupt".utf8)
        LFSTransferURLProtocol.install { request in
            request.url?.lastPathComponent == "batch" ? .batch(request) : LFSTransferReply(body: corrupt)
        }
        try await run { client, store, _ in
            do {
                try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: Int64(data.count))])
                Issue.record("corrupt download succeeded")
            } catch {
                #expect(String(describing: error) == "expected OID \(oid), got \(hash(corrupt)) after 7 bytes written")
            }
            #expect(!FileManager.default.fileExists(atPath: store.objectPathname(oid).path))
            let saved = try Data(contentsOf: store.incompleteDirectory.appendingPathComponent(oid + ".part"))
            #expect(saved == corrupt)
            #expect(LFSTransferURLProtocol.requests.count == 2)
        }
    }

    @Test("206 resumes the part and counts the existing prefix as progress")
    func resume() async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4-11")
            return LFSTransferReply(status: 206, headers: ["Content-Range": "bytes 4-11/12"], body: data.dropFirst(4))
        }
        try await run { client, store, _ in
            _ = try await part(store, prefix: data.prefix(4))
            let calls = TransferTestLock<[[Int64]]>([])
            let transfer = LFSTransferQueue(client: client, store: store, direction: .download,
                remote: "", refName: "", progress: { direction, name, total, read, delta in
                    #expect(direction == .download && name == "file" && total == 12)
                    calls.withLock { $0.append([read, delta]) }
                })
            try await transfer.transfer([LFSBatchObject(oid: oid, size: 12, name: "file")])
            #expect(try Data(contentsOf: store.objectPathname(oid)) == data)
            #expect(calls.withLock { $0.first } == [4, 4])
            #expect(calls.withLock { $0.last } == [12, 8])
        }
    }

    @Test("200 replaces a ranged part; invalid ranges and 416 restart without Range",
          arguments: [200, 206, 416, 403])
    func rangeFallback(status: Int) async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            if request.value(forHTTPHeaderField: "Range") != nil {
                return LFSTransferReply(status: status, headers: ["Content-Range": "bytes 2-11/12"], body: data)
            }
            return LFSTransferReply(body: data)
        }
        try await run { client, store, _ in
            _ = try await part(store, prefix: data.prefix(4))
            try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: 12)])
            #expect(try Data(contentsOf: store.objectPathname(oid)) == data)
            #expect(LFSTransferURLProtocol.requests.count == (status == 200 ? 2 : 3))
            if status != 200 {
                #expect(LFSTransferURLProtocol.requests.last?.value(forHTTPHeaderField: "Range") == nil)
            }
        }
    }

    @Test("a part of size minus one or more starts over", arguments: [11, 12, 15])
    func oversizedPart(length: Int) async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            return LFSTransferReply(body: data)
        }
        try await run { client, store, _ in
            _ = try await part(store, prefix: Data(repeating: 0, count: length))
            try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: 12)])
            #expect(try Data(contentsOf: store.objectPathname(oid)) == data)
        }
    }

    @Test("no upload action silently skips an object already on the server")
    func noUploadAction() async throws {
        LFSTransferURLProtocol.install { _ in
            LFSTransferReply(body: Data(#"{"objects":[{"oid":"\#(oid)","size":12}]}"#.utf8))
        }
        try await run { client, store, _ in
            try await queue(client, store, .upload).transfer(
                [LFSBatchObject(oid: oid, size: 12)])
            #expect(LFSTransferURLProtocol.requests.count == 1)
        }
    }

    @Test("no download action reports that the object was not found")
    func noDownloadAction() async throws {
        LFSTransferURLProtocol.install { _ in
            LFSTransferReply(body: Data(#"{"objects":[{"oid":"\#(oid)","size":12}]}"#.utf8))
        }
        try await run { client, store, _ in
            await #expect(throws: LFSClientError("Object \(oid) not found on the server.")) {
                try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: 12)])
            }
            #expect(LFSTransferURLProtocol.requests.count == 1)
            #expect(!FileManager.default.fileExists(atPath: store.objectPathname(oid).path))
        }
    }

    @Test("PUT streams the file then POSTs verify with the LFS media type")
    func uploadAndVerify() async throws {
        try await LFSTestServer.withServer { server in
            try await run(
                config: [("lfs.url", server.endpoint.absoluteString)],
                sessionConfiguration: .ephemeral
            ) { client, store, directory in
                let file = directory.appendingPathComponent("file")
                try data.write(to: file)
                try await queue(client, store, .upload).transfer([
                    LFSBatchObject(oid: oid, size: 12, path: file.path)
                ])
            }

            let requests = server.requests()
            #expect(requests.map(\.method) == ["POST", "PUT", "POST"])
            let upload = try #require(requests.first { $0.method == "PUT" })
            #expect(upload.requestHeaders["content-length"] == "12")
            #expect(upload.requestHeaders["content-type"] == "text/plain; charset=utf-8")
            #expect(upload.requestBody == data)
            #expect(server.bytes(for: oid) == data)

            let verify = try #require(requests.last)
            #expect(verify.requestHeaders["content-type"] == LFSMediaType.json)
            #expect(verify.requestHeaders["accept"] == LFSMediaType.json)
            #expect(verify.requestBody == Data(#"{"oid":"\#(oid)","size":12}"#.utf8))
        }
    }

    @Test("429 honors Retry-After and 503 ignores it", arguments: [429, 503])
    func retryAfter(status: Int) async throws {
        let attempts = TransferTestLock(0)
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            let count = attempts.withLock { $0 += 1; return $0 }
            if count == 1 { return LFSTransferReply(status: status, headers: ["Retry-After": "7"]) }
            return LFSTransferReply(body: data)
        }
        try await run { client, store, _ in
            let clock = LFSTransferClock()
            try await queue(client, store, clock: clock).transfer([LFSBatchObject(oid: oid, size: 12)])
            #expect(clock.delays == [status == 429 ? 7 : 0.25])
            #expect(LFSTransferURLProtocol.requests.count == 4)
        }
    }

    @Test("retry exhaustion returns only the last HTTP message")
    func exhaustion() async throws {
        let attempts = TransferTestLock(0)
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            let count = attempts.withLock { $0 += 1; return $0 }
            return LFSTransferReply(status: 500, body: Data(#"{"message":"failure \#(count)"}"#.utf8))
        }
        try await run(config: [("lfs.transfer.maxretries", "1")]) { client, store, _ in
            await #expect(throws: LFSClientError("failure 2")) {
                try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: 12)])
            }
            #expect(attempts.withLock { $0 } == 2)
        }
    }

    @Test("422 does one PUT per object and prints the contenttype block once")
    func unsupportedContentType() async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request, operation: "upload") }
            return LFSTransferReply(status: 422, body: Data(#"{"message":"unsupported"}"#.utf8))
        }
        try await run { client, store, directory in
            let file = directory.appendingPathComponent("file")
            try data.write(to: file)
            let clock = LFSTransferClock()
            await #expect(throws: LFSClientError("unsupported\nunsupported")) {
                try await queue(client, store, .upload, clock: clock).transfer([
                    LFSBatchObject(oid: oid, size: 12, path: file.path),
                    LFSBatchObject(oid: String(repeating: "a", count: 64), size: 12, path: file.path)])
            }
            #expect(clock.stderr == LFSTransferQueue.contentTypeInfo)
            #expect(LFSTransferURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count == 2)
            #expect(clock.delays.isEmpty)
        }
    }
}
