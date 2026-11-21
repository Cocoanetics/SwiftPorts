import Crypto
import Foundation
import GitLFSTestSupport
import Testing

@Suite("LFSTestServerTests", .timeLimit(.minutes(2)))
struct LFSTestServerTests {
    @Test("100 Continue precedes a drained 1 MB PUT and its final status",
          arguments: [200, 503, 401], [false, true])
    func largeUpload(code: Int, chunked: Bool) async throws {
        let bytes = Data(repeating: 0x61, count: 1_000_000)
        let oid = sha256Hex(bytes)
        // Keep this control independent of URLSession. The same server must read
        // the entire body even when it is about to return an error.
        try await LFSWireClient.withServer { server, client in
            if code != 200 { server.inject(.putStatus(oid: oid, code: code)) }
            let href = server.endpoint.absoluteString + "/objects/" + oid
            // The client waits for 100 before sending the first 32 KiB chunk.
            let response = try await client.put(href, body: bytes, expectContinue: true, chunked: chunked)
            #expect(response.status == code)
            let put = try #require(server.requests().first { $0.method == "PUT" })
            #expect(put.status == code)
            #expect(put.requestBody == bytes)
            #expect(put.requestHeaders["expect"] == "100-continue")
            #expect(put.requestHeaders["content-length"] == (chunked ? nil : String(bytes.count)))
            #expect(put.requestHeaders["transfer-encoding"] == (chunked ? "chunked" : nil))
            #expect(server.bytes(for: oid) == (code == 200 ? bytes : nil))
        }
    }

    @Test("a batch, GET, PUT, and verify round trip")
    func roundTrip() async throws {
        let bytes = Data("hello\n".utf8)
        let oid = sha256Hex(bytes)
        try await LFSWireClient.withServer { server, client in
            #expect(server.endpoint.host == "127.0.0.1")
            #expect(server.port != 0)
            let uploaded = try await client.postBatch(
                server, operation: "upload", objects: [(oid: oid, size: bytes.count)]
            )
            #expect(uploaded.status == 200)
            let uploadDocument = try LFSWireClient.document(uploaded)
            #expect(uploadDocument.transfer == "basic")
            let upload = try #require(uploadDocument.object(oid)?.actions?["upload"])
            let verify = try #require(uploadDocument.object(oid)?.actions?["verify"])
            expectAction(upload, on: server)
            expectAction(verify, on: server)
            #expect(rfc3339(upload.expiresAt) ?? .distantPast > Date())

            let put = try await client.put(upload.href, body: bytes)
            #expect(put.status == 200)
            let verified = try await client.verify(verify.href, oid: oid, size: bytes.count)
            #expect(verified.status == 200)
            #expect(server.bytes(for: oid) == bytes)

            let downloaded = try await client.postBatch(
                server, operation: "download", objects: [(oid: oid, size: bytes.count)]
            )
            #expect(downloaded.status == 200)
            let download = try #require(try LFSWireClient.document(downloaded).object(oid)?.actions?["download"])
            expectAction(download, on: server)
            let got = try await client.get(download.href)
            #expect(got.status == 200)
            #expect(got.body == bytes)

            let log = server.requests()
            let putIndex = try #require(log.firstIndex { $0.method == "PUT" })
            let verifyIndex = try #require(log.firstIndex { $0.path.hasSuffix("/verify") })
            #expect(putIndex < verifyIndex)
            #expect(log[putIndex].requestBody == bytes)
            #expect(log[putIndex].status == 200)
            #expect(log[verifyIndex].method == "POST")
            #expect(log[verifyIndex].status == 200)
            #expect(String(decoding: log[verifyIndex].requestBody, as: UTF8.self).contains(oid))
            let get = try #require(log.first { $0.method == "GET" })
            #expect(get.status == 200)
            #expect(get.responseBody == bytes)
            #expect(log.filter { $0.path == "/objects/batch" }.count == 2)
        }
    }

    @Test("verify rejects an upload whose SHA-256 is not the oid")
    func verifyRejectsMismatchedDigest() async throws {
        let bytes = Data("hello\n".utf8)
        let oid = sha256Hex(bytes)
        var corrupt = bytes
        corrupt[corrupt.startIndex] ^= 0xFF
        #expect(corrupt.count == bytes.count)
        #expect(sha256Hex(corrupt) != oid)
        try await LFSWireClient.withServer { server, client in
            let uploaded = try await client.postBatch(
                server, operation: "upload", objects: [(oid: oid, size: bytes.count)]
            )
            let actions = try #require(try LFSWireClient.document(uploaded).object(oid)?.actions)
            let upload = try #require(actions["upload"]?.href)
            let verify = try #require(actions["verify"]?.href)
            let put = try await client.put(upload, body: corrupt)
            #expect(put.status == 200)
            let verified = try await client.verify(verify, oid: oid, size: bytes.count)
            #expect(verified.status == 422)
            let message = try JSONDecoder().decode(ErrorEnvelope.self, from: verified.body).message
            #expect(message == "Validation error")
            let entry = try #require(server.requests().last { $0.path.hasSuffix("/verify") })
            #expect(entry.method == "POST")
            #expect(entry.status == 422)
            #expect(entry.responseBody == verified.body)
            #expect(server.bytes(for: oid) == nil)

            let again = try await client.postBatch(
                server, operation: "upload", objects: [(oid: oid, size: bytes.count)]
            )
            let retry = try #require(try LFSWireClient.document(again).object(oid))
            #expect(retry.error == nil)
            #expect(retry.actions?["upload"] != nil)
            let got = try await client.get(upload)
            #expect(got.status == 404)
            #expect(got.body != corrupt)
        }
    }

    @Test("an object the server already has has no upload action")
    func alreadyPresentHasNoUploadAction() async throws {
        let present = Data("already\n".utf8)
        let missing = Data("missing\n".utf8)
        let presentOID = sha256Hex(present)
        let missingOID = sha256Hex(missing)
        try await LFSWireClient.withServer { server, client in
            server.store(present, oid: presentOID)
            let response = try await client.postBatch(
                server,
                operation: "upload",
                objects: [(oid: presentOID, size: present.count), (oid: missingOID, size: missing.count)]
            )
            #expect(response.status == 200)
            let document = try LFSWireClient.document(response)
            let stored = try #require(document.object(presentOID))
            #expect(stored.size == present.count)
            #expect(stored.error == nil)
            #expect(stored.actions?["upload"] == nil)
            let fresh = try #require(document.object(missingOID))
            let upload = try #require(fresh.actions?["upload"])
            #expect(upload.href.hasPrefix(server.endpoint.absoluteString + "/objects/"))
            #expect(fresh.actions?["verify"] != nil)
        }
    }

    @Test("parallel GET and PUT of N objects")
    func parallelTransfers() async throws {
        let count = 8
        let downloads = (0..<count).map { Data("download-\($0)\n".utf8) }
        let uploads = (0..<count).map { Data("upload-\($0)\n".utf8) }
        try await LFSWireClient.withServer { server, client in
            for payload in downloads {
                server.store(payload, oid: sha256Hex(payload))
            }
            let downloadBatch = try await client.postBatch(
                server,
                operation: "download",
                objects: downloads.map { (oid: sha256Hex($0), size: $0.count) }
            )
            #expect(downloadBatch.status == 200)
            try await fetchAll(client, try LFSWireClient.document(downloadBatch), expected: downloads)

            let uploadBatch = try await client.postBatch(
                server,
                operation: "upload",
                objects: uploads.map { (oid: sha256Hex($0), size: $0.count) }
            )
            #expect(uploadBatch.status == 200)
            try await putAll(client, try LFSWireClient.document(uploadBatch), payloads: uploads)
            for payload in uploads {
                #expect(server.bytes(for: sha256Hex(payload)) == payload)
            }
            let gets = server.requests().filter { $0.method == "GET" && $0.status == 200 }
            let puts = server.requests().filter { $0.method == "PUT" && $0.status == 200 }
            #expect(gets.count == count)
            #expect(puts.count == count)
        }
    }

    @Test("held object transfers report how many ran at once")
    func heldTransfersOverlap() async throws {
        let overlap = 4
        let payloads = (0..<overlap + 1).map { Data("overlap-\($0)\n".utf8) }
        try await LFSWireClient.withServer { server, client in
            for payload in payloads { server.store(payload, oid: sha256Hex(payload)) }
            await server.holdObjectTransfers(untilInFlight: overlap, timeout: .seconds(5))
            let batch = try await client.postBatch(
                server,
                operation: "download",
                objects: payloads.map { (oid: sha256Hex($0), size: $0.count) }
            )
            #expect(batch.status == 200)
            try await fetchAll(client, try LFSWireClient.document(batch), expected: payloads)
            #expect(await server.peakObjectTransfers() >= overlap)
            let gets = server.requests().filter { $0.method == "GET" && $0.status == 200 }
            #expect(gets.count == payloads.count)
        }
    }

    @Test("one object transfer does not satisfy an overlap hold")
    func heldTransferStaysSerial() async throws {
        let payloads = [Data("one\n".utf8), Data("two\n".utf8)]
        try await LFSWireClient.withServer { server, client in
            for payload in payloads { server.store(payload, oid: sha256Hex(payload)) }
            await server.holdObjectTransfers(untilInFlight: 2, timeout: .milliseconds(300))
            let batch = try await client.postBatch(
                server,
                operation: "download",
                objects: payloads.map { (oid: sha256Hex($0), size: $0.count) }
            )
            let document = try LFSWireClient.document(batch)
            for payload in payloads {
                let href = try #require(document.object(sha256Hex(payload))?.actions?["download"]?.href)
                let got = try await client.get(href)
                #expect(got.status == 200)
                #expect(got.body == payload)
            }
            #expect(await server.peakObjectTransfers() == 1)
        }
    }
}

private struct PendingUpload: Sendable {
    var href: String
    var body: Data
}

private struct DownloadLink: Sendable {
    var oid: String
    var href: String
}

private struct FetchedObject: Sendable {
    var oid: String
    var status: Int
    var body: Data
}

private func fetchAll(_ client: LFSWireClient, _ document: BatchDocument, expected: [Data]) async throws {
    let byOID = Dictionary(uniqueKeysWithValues: expected.map { (sha256Hex($0), $0) })
    let links: [DownloadLink] = try document.objects.map { object in
        DownloadLink(oid: object.oid, href: try #require(object.actions?["download"]?.href))
    }
    try await withThrowingTaskGroup(of: FetchedObject.self) { group in
        for link in links {
            group.addTask {
                let response = try await client.get(link.href)
                return FetchedObject(oid: link.oid, status: response.status, body: response.body)
            }
        }
        var seen = 0
        for try await fetched in group {
            #expect(fetched.status == 200)
            #expect(fetched.body == byOID[fetched.oid])
            seen += 1
        }
        #expect(seen == expected.count)
    }
}

private func putAll(_ client: LFSWireClient, _ document: BatchDocument, payloads: [Data]) async throws {
    let byOID = Dictionary(uniqueKeysWithValues: payloads.map { (sha256Hex($0), $0) })
    let pending: [PendingUpload] = try document.objects.map { object in
        PendingUpload(
            href: try #require(object.actions?["upload"]?.href),
            body: try #require(byOID[object.oid])
        )
    }
    try await withThrowingTaskGroup(of: Int.self) { group in
        for item in pending {
            group.addTask {
                try await client.put(item.href, body: item.body).status
            }
        }
        var seen = 0
        for try await status in group {
            #expect(status == 200)
            seen += 1
        }
        #expect(seen == payloads.count)
    }
}

func expectAction(_ action: BatchAction, on server: LFSTestServer) {
    #expect(action.href.hasPrefix(server.endpoint.absoluteString + "/objects/"))
    #expect(action.header.isEmpty)
    #expect(!action.expiresAt.isEmpty)
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func rfc3339(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: value)
}
