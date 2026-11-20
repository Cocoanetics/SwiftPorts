import Foundation
import HTTPTypes
import SwiftGit
import Testing
@testable import GitLFSKit

extension LFSTransferQueueTests {
    @Test("object authentication retries once only when no authorization was sent")
    func oneAuthRetry() async throws {
        let calls = TransferTestLock(0)
        LFSTransferURLProtocol.install { request in
            LFSTransferReply(status: request.value(forHTTPHeaderField: "Authorization") == nil ? 401 : 200)
        }
        let provider: CredentialProvider = { _, _, _ in
            calls.withLock { $0 += 1 }
            return .userPassword(username: "test", password: "secret")
        }
        try await run(provider: provider) { client, _, _ in
            let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/object")!)
            let result = try await client.transfer(request, operation: "download", remote: nil, authenticated: false)
            #expect(result.status == 200)
            #expect(calls.withLock { $0 } == 1)
            #expect(LFSTransferURLProtocol.requests.count == 2)
        }
    }

    @Test("a rejected credential is not retried inside the object request")
    func rejectedCredential() async throws {
        let calls = TransferTestLock(0)
        LFSTransferURLProtocol.install { _ in LFSTransferReply(status: 401) }
        let provider: CredentialProvider = { _, _, _ in
            calls.withLock { $0 += 1 }
            return .userPassword(username: "test", password: "wrong")
        }
        try await run(provider: provider) { client, _, _ in
            let request = HTTPRequest(method: .get, url: URL(string: "https://example.com/object")!)
            let result = try await client.transfer(request, operation: "download", remote: nil, authenticated: false)
            #expect(result.status == 401)
            #expect(calls.withLock { $0 } == 1)
            #expect(LFSTransferURLProtocol.requests.count == 2)
        }
    }

    @Test("action authorization, query tokens, and authenticated actions do not retry 401",
          arguments: ["header", "token", "authenticated"])
    func actionAuthorization(mode: String) async throws {
        LFSTransferURLProtocol.install { _ in LFSTransferReply(status: 401) }
        let provider: CredentialProvider = { _, _, _ in
            Issue.record("unexpected credential lookup")
            return nil
        }
        try await run(provider: provider) { client, _, _ in
            let suffix = mode == "token" ? "?token=abc" : ""
            var request = HTTPRequest(method: .get, url: URL(string: "https://example.com/object" + suffix)!)
            if mode == "header" { request.headerFields[.authorization] = "Bearer action" }
            let result = try await client.transfer(
                request, operation: "download", remote: nil, authenticated: mode == "authenticated")
            #expect(result.status == 401)
            #expect(LFSTransferURLProtocol.requests.count == 1)
        }
    }

    @Test("the second worker waits for a successful response, then overlaps the first body")
    func authGate() async throws {
        let arrived = LFSTransferSignal()
        let allowResponse = LFSTransferSignal()
        let secondArrived = LFSTransferSignal()
        let otherData = Data("other".utf8)
        let otherOID = hash(otherData)
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            if request.url?.lastPathComponent == oid {
                return LFSTransferReply(body: data, beforeResponse: {
                    await arrived.signal()
                    await allowResponse.wait()
                }, beforeBody: { await secondArrived.wait() })
            }
            return LFSTransferReply(body: otherData, beforeResponse: { await secondArrived.signal() })
        }
        try await run(config: [("lfs.concurrenttransfers", "2")]) { client, store, _ in
            let task = Task {
                try await queue(client, store).transfer([
                    LFSBatchObject(oid: otherOID, size: 5), LFSBatchObject(oid: oid, size: 12)])
            }
            await arrived.wait()
            #expect(LFSTransferURLProtocol.requests.count == 2)
            await allowResponse.signal()
            try await task.value
            #expect(LFSTransferURLProtocol.requests.count == 3)
        }
    }

    @Test("an unsuccessful first worker drains the jobs, reports failures, and releases all waiters")
    func failedAuthGate() async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request, operation: "upload") }
            return LFSTransferReply(status: 422)
        }
        try await run(config: [("lfs.concurrenttransfers", "3")]) { client, store, directory in
            let path = directory.appendingPathComponent("upload")
            try data.write(to: path)
            let objects = (1...4).map {
                LFSBatchObject(oid: String(repeating: String($0), count: 64), size: 12, path: path.path)
            }
            let expected = objects.map {
                "Unprocessable entity: https://example.com/objects/\($0.oid)"
            }.joined(separator: "\n")
            await #expect(throws: LFSClientError(expected)) {
                try await queue(client, store, .upload).transfer(objects)
            }
            #expect(LFSTransferURLProtocol.requests.count == 5)
        }
    }
}
