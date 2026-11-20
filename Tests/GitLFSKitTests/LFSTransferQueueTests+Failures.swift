import Foundation
import Testing
@testable import GitLFSKit

extension LFSTransferQueueTests {
    @Test("a failed verify uses at least three attempts and returns its last error", arguments: [false, true])
    func verifyExhaustion(authenticated: Bool) async throws {
        let verifies = TransferTestLock(0)
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" {
                return .batch(request, operation: "upload", verify: true, authenticated: authenticated)
            }
            if request.httpMethod == "PUT" { return LFSTransferReply() }
            let count = verifies.withLock { $0 += 1; return $0 }
            return LFSTransferReply(status: 500, body: Data(#"{"message":"verify \#(count)"}"#.utf8))
        }
        try await run(config: [("lfs.transfer.maxverifies", "1")]) { client, store, directory in
            let path = directory.appendingPathComponent("upload")
            try data.write(to: path)
            await #expect(throws: LFSClientError("verify 3")) {
                try await queue(client, store, .upload).transfer([LFSBatchObject(oid: oid, size: 12, path: path.path)])
            }
            #expect(verifies.withLock { $0 } == 3)
            #expect(LFSTransferURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count == 1)
        }
    }

    @Test("a final verify 429 retries the object after Retry-After", arguments: [false, true])
    func verifyRetryAfter(authenticated: Bool) async throws {
        let verifies = TransferTestLock(0)
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" {
                return .batch(request, operation: "upload", verify: true, authenticated: authenticated)
            }
            if request.httpMethod == "PUT" { return LFSTransferReply() }
            let count = verifies.withLock { $0 += 1; return $0 }
            if count <= 3 {
                return LFSTransferReply(
                    status: 429, headers: ["Retry-After": "7"],
                    body: Data(#"{"message":"rate limited"}"#.utf8))
            }
            return LFSTransferReply()
        }
        try await run { client, store, directory in
            let path = directory.appendingPathComponent("upload")
            try data.write(to: path)
            let clock = LFSTransferClock()
            try await queue(client, store, .upload, clock: clock).transfer([
                LFSBatchObject(oid: oid, size: 12, path: path.path)])
            #expect(clock.delays == [7])
            #expect(verifies.withLock { $0 } == 4)
            #expect(LFSTransferURLProtocol.requests.filter { $0.httpMethod == "PUT" }.count == 2)
        }
    }

    @Test("eight retries means nine attempts and capped backoff")
    func defaultRetries() async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            return LFSTransferReply(status: 503, body: Data(#"{"message":"last failure"}"#.utf8))
        }
        try await run { client, store, _ in
            let clock = LFSTransferClock()
            await #expect(throws: LFSClientError("last failure")) {
                try await queue(client, store, clock: clock).transfer([LFSBatchObject(oid: oid, size: 12)])
            }
            #expect(clock.delays == [0.25, 0.5, 1, 2, 4, 8, 10, 10])
            #expect(LFSTransferURLProtocol.requests.count == 18)
        }
    }

    @Test("batch HTTP failure is retried per object and exhaustion returns the last error")
    func batchFailure() async throws {
        let attempts = TransferTestLock(0)
        LFSTransferURLProtocol.install { _ in
            let count = attempts.withLock { $0 += 1; return $0 }
            return LFSTransferReply(status: 500, body: Data(#"{"message":"batch failed \#(count)"}"#.utf8))
        }
        try await run(config: [("lfs.transfer.maxretries", "1")]) { client, store, _ in
            let clock = LFSTransferClock()
            await #expect(throws: LFSClientError("batch failed 2")) {
                try await queue(client, store, clock: clock).transfer([LFSBatchObject(oid: oid, size: 12)])
            }
            #expect(attempts.withLock { $0 } == 2)
            #expect(clock.delays == [0.25])
        }
    }

    @Test("batch expiration exhaustion is not retried by the transfer queue")
    func batchExpiration() async throws {
        let body = """
        {"objects":[{"oid":"\(oid)","size":12,"actions":{"download":{
        "href":"https://example.com/expired","expires_at":"2000-01-01T00:00:00Z"}}}]}
        """
        LFSTransferURLProtocol.install { _ in LFSTransferReply(body: Data(body.utf8)) }
        try await run { client, store, _ in
            let clock = LFSTransferClock()
            let at = try #require(LFSTimestamp.parse("2000-01-01T00:00:00Z"))
            let expected = "[blob.bin] LFS: action \"download\" expires at \(LFSTimestamp.rfc822(at))"
            await #expect(throws: LFSClientError(expected)) {
                try await queue(client, store, clock: clock).transfer([
                    LFSBatchObject(oid: oid, size: 12, name: "blob.bin")])
            }
            #expect(LFSTransferURLProtocol.requests.count == 9)
            #expect(clock.delays.isEmpty)
        }
    }

    @Test("an unknown OID in a batch response is reported")
    func unknownOID() async throws {
        let unknown = String(repeating: "a", count: 64)
        LFSTransferURLProtocol.install { _ in
            LFSTransferReply(body: Data(#"{"objects":[{"oid":"\#(unknown)","size":12}]}"#.utf8))
        }
        try await run { client, store, _ in
            let expected = "[\(unknown)] The server returned an unknown OID.\n"
                + "[\(oid)] The server did not return the requested OID."
            await #expect(throws: LFSClientError(expected)) {
                try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: 12)])
            }
            #expect(LFSTransferURLProtocol.requests.count == 1)
        }
    }

    @Test("duplicate OIDs in a batch response are transferred once")
    func duplicateResponseOID() async throws {
        let object = #"{"oid":"\#(oid)","size":12,"actions":{"download":{"href":"https://example.com/object"}}}"#
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" {
                return LFSTransferReply(body: Data("{\"objects\":[\(object),\(object)]}".utf8))
            }
            return LFSTransferReply(body: data)
        }
        try await run(config: [("lfs.concurrenttransfers", "2")]) { client, store, _ in
            try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: 12)])
            #expect(try Data(contentsOf: store.objectPathname(oid)) == data)
            #expect(LFSTransferURLProtocol.requests.count == 2)
        }
    }

    @Test("requested OIDs omitted from a batch response are reported")
    func omittedOID() async throws {
        let omitted = String(repeating: "a", count: 64)
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" {
                let object = #"{"oid":"\#(oid)","size":12,"actions":{"download":{"href":"https://example.com/object"}}}"#
                return LFSTransferReply(body: Data("{\"objects\":[\(object)]}".utf8))
            }
            return LFSTransferReply(body: data)
        }
        try await run { client, store, _ in
            await #expect(throws: LFSClientError("[\(omitted)] The server did not return the requested OID.")) {
                try await queue(client, store).transfer([
                    LFSBatchObject(oid: oid, size: 12),
                    LFSBatchObject(oid: omitted, size: 12)])
            }
            #expect(LFSTransferURLProtocol.requests.count == 2)
        }
    }

    @Test("an upload whose file size changed is rejected before PUT")
    func corruptUpload() async throws {
        LFSTransferURLProtocol.install { request in
            request.url?.lastPathComponent == "batch"
                ? .batch(request, operation: "upload") : LFSTransferReply()
        }
        try await run { client, store, directory in
            let path = directory.appendingPathComponent("upload")
            try data.write(to: path)
            await #expect(throws: LFSClientError("corrupt object: file (\(oid))")) {
                try await queue(client, store, .upload).transfer([
                    LFSBatchObject(oid: oid, size: 11, name: "file", path: path.path)])
            }
            #expect(LFSTransferURLProtocol.requests.map(\.httpMethod) == ["POST"])
        }
    }

    @Test("object errors do not cancel other objects and are not retried")
    func objectError() async throws {
        let failedOID = String(repeating: "f", count: 64)
        LFSTransferURLProtocol.install { request in
            guard request.url?.lastPathComponent == "batch" else { return LFSTransferReply(body: data) }
            let failed = #"{"oid":"\#(failedOID)","size":30,"error":{"code":404,"message":"gone"}}"#
            let valid = #"{"oid":"\#(oid)","size":12,"actions":{"download":{"href":"https://example.com/object"}}}"#
            return LFSTransferReply(body: Data("{\"objects\":[\(failed),\(valid)]}".utf8))
        }
        try await run { client, store, _ in
            await #expect(throws: LFSClientError("[\(failedOID)] gone: [404] gone")) {
                try await queue(client, store).transfer([
                    LFSBatchObject(oid: failedOID, size: 30), LFSBatchObject(oid: oid, size: 12)])
            }
            let stored = try Data(contentsOf: store.objectPathname(oid))
            #expect(stored == data)
            #expect(LFSTransferURLProtocol.requests.count == 2)
        }
    }

    @Test("a transport failure retains downloaded bytes for the next ranged attempt")
    func interruptedDownload() async throws {
        let attempts = TransferTestLock(0)
        let written = LFSTransferSignal()
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            let count = attempts.withLock { $0 += 1; return $0 }
            if count == 1 {
                return LFSTransferReply(body: data.prefix(4), failure: URLError(.networkConnectionLost),
                                        afterBody: { await written.wait() })
            }
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4-11")
            return LFSTransferReply(status: 206, headers: ["Content-Range": "bytes 4-11/12"], body: data.dropFirst(4))
        }
        try await run { client, store, _ in
            let clock = LFSTransferClock()
            let transfer = LFSTransferQueue(client: client, store: store, direction: .download,
                remote: "", refName: "", progress: { _, _, _, read, _ in
                    if read == 4 { Task { await written.signal() } }
                }, environment: clock.environment)
            try await transfer.transfer([LFSBatchObject(oid: oid, size: 12)])
            #expect(try Data(contentsOf: store.objectPathname(oid)) == data)
        }
    }

    @Test("chunked upload omits Content-Length")
    func chunkedUpload() async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" {
                return .batch(request, operation: "upload", headers: ["Transfer-Encoding": "chunked"])
            }
            #expect(request.value(forHTTPHeaderField: "Content-Length") == nil)
            // URLSession owns Transfer-Encoding and strips it before URLProtocol.
            // The unknown-length disk stream must retain the actual file bytes.
            #expect(request.httpBody == data)
            return LFSTransferReply()
        }
        try await run { client, store, directory in
            let path = directory.appendingPathComponent("upload")
            try data.write(to: path)
            try await queue(client, store, .upload).transfer([LFSBatchObject(oid: oid, size: 12, path: path.path)])
            #expect(LFSTransferURLProtocol.requests.count == 2)
        }
    }
}
