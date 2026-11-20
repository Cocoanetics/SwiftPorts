import Foundation
import HTTPTypes
import Testing
@testable import GitLFSKit

extension LFSTransferQueueTests {
    @Test("upload contenttype configuration, action headers and PNG detection", arguments: ["off", "header", "png"])
    func contentType(option: String) async throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" {
                return .batch(request, operation: "upload",
                              headers: option == "header" ? ["Content-Type": "custom"] : [:])
            }
            let expected = option == "off" ? "application/octet-stream" : option == "header" ? "custom" : "image/png"
            #expect(request.value(forHTTPHeaderField: "Content-Type") == expected)
            return LFSTransferReply()
        }
        try await run(config: [("lfs.contenttype", option == "off" ? "false" : "true")]) { client, store, directory in
            let path = directory.appendingPathComponent("upload")
            try png.write(to: path)
            try await queue(client, store, .upload).transfer([LFSBatchObject(oid: oid, size: 8, path: path.path)])
        }
    }

    @Test("href rewrite applies aliases only when enabled and never appends info/lfs", arguments: [false, true])
    func hrefRewrite(enabled: Bool) async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            #expect(request.url?.host == (enabled ? "rewritten.example" : "example.com"))
            #expect(request.url?.path == "/objects/" + oid)
            return LFSTransferReply(body: data)
        }
        try await run(config: [("lfs.transfer.enablehrefrewrite", enabled ? "true" : "false"),
                              ("url.https://rewritten.example/.insteadof", "https://example.com/")]) { client, store, _ in
            try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: 12)])
        }
    }

    @Test("transfer options use positive defaults, decimal integers and the safe list")
    func settings() async throws {
        try await run(config: [("lfs.concurrenttransfers", "0"), ("lfs.transfer.maxretries", "-1"),
                              ("lfs.transfer.maxretrydelay", "0"), ("lfs.transfer.batchSize", "0"),
                              ("lfs.transfer.maxverifies", "1")]) { client, _, _ in
            let settings = LFSTransferSettings(client.finder.configuration)
            #expect(settings.concurrency == 8 && settings.maxRetries == 8 && settings.maxRetryDelay == 10)
            #expect(settings.batchSize == 100 && settings.maxVerifies == 3 && !settings.rewrite)
        }
        try await run(config: [("lfs.concurrenttransfers", "2k"), ("lfs.transfer.batchSize", "+7")]) { client, _, _ in
            #expect(LFSTransferSettings(client.finder.configuration).concurrency == 8)
            #expect(LFSTransferSettings(client.finder.configuration).batchSize == 7)
        }
        for key in ["lfs.concurrenttransfers", "lfs.transfer.maxretries", "lfs.transfer.maxretrydelay",
                    "lfs.transfer.batchsize", "lfs.transfer.maxverifies", "lfs.transfer.enablehrefrewrite"] {
            #expect(!LFSConfiguration.allowed(key))
        }
    }

    @Test("batch size, descending sizes, ref, and first duplicate name/path are preserved")
    func batching() async throws {
        let sizes = TransferTestLock<[Int64]>([])
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" {
                let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
                let objects = json?["objects"] as? [[String: Any]] ?? []
                #expect(objects.count <= 2)
                #expect((json?["ref"] as? [String: String])?["name"] == "refs/heads/main")
                sizes.withLock { $0 += objects.compactMap { $0["size"] as? Int64 } }
                return .batch(request, operation: "upload")
            }
            return LFSTransferReply()
        }
        try await run(config: [("lfs.transfer.batchSize", "2"), ("lfs.concurrenttransfers", "1")]) {
            client, store, directory in
            let path = directory.appendingPathComponent("upload")
            try data.write(to: path)
            let first = LFSBatchObject(oid: oid, size: 12, name: "first", path: path.path)
            let second = LFSBatchObject(oid: String(repeating: "b", count: 64), size: 20, path: path.path)
            let third = LFSBatchObject(oid: String(repeating: "c", count: 64), size: 3, path: path.path)
            try await queue(client, store, .upload).transfer([
                first, second, LFSBatchObject(oid: oid, size: 80, path: "/missing"), third])
            #expect(sizes.withLock { $0 } == [20, 12, 3])
        }
    }

    @Test("an action that expires after batch returns is requested in the next batch")
    func expiresBeforeUse() async throws {
        let batches = TransferTestLock(0)
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent != "batch" { return LFSTransferReply(body: data) }
            let count = batches.withLock { $0 += 1; return $0 }
            if count == 1 {
                let object = #"{"oid":"\#(oid)","size":12,"actions":{"download":{"href":"https://example.com/expired","expires_in":60}}}"#
                return LFSTransferReply(body: Data("{\"objects\":[\(object)]}".utf8))
            }
            return .batch(request)
        }
        try await run { client, store, _ in
            var environment = LFSTransferClock().environment
            // Expiration is immediately ready for the following batch.
            let now = TransferTestLock(Date().addingTimeInterval(120))
            environment.now = { now.withLock { $0 } }
            environment.sleep = { seconds in now.withLock { $0 += seconds } }
            let transfer = LFSTransferQueue(client: client, store: store, direction: .download,
                remote: "", refName: "", environment: environment)
            try await transfer.transfer([LFSBatchObject(oid: oid, size: 12)])
            #expect(batches.withLock { $0 } == 2)
            #expect(LFSTransferURLProtocol.requests.count == 3)
            #expect(LFSTransferURLProtocol.requests.last?.url?.lastPathComponent == oid)
        }
    }

    @Test("file action keeps the missing protocol error")
    func fileAction() async throws {
        LFSTransferURLProtocol.install { _ in
            let object = #"{"oid":"\#(oid)","size":12,"actions":{"download":{"href":"file:///tmp/object"}}}"#
            return LFSTransferReply(body: Data("{\"objects\":[\(object)]}".utf8))
        }
        try await run { client, store, _ in
            await #expect(throws: LFSClientError(#"missing protocol: "file:///tmp/object""#)) {
                try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: 12)])
            }
            #expect(LFSTransferURLProtocol.requests.count == 1)
        }
    }
}
