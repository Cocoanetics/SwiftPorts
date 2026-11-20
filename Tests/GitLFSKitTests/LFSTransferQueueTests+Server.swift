import Foundation
import GitLFSTestSupport
import Testing
@testable import GitLFSKit

extension LFSTransferQueueTests {
    @Test("parallel download and upload of several objects")
    func parallelTransfers() async throws {
        let downloads = (0..<4).map { Data("download \($0)\n".utf8) }
        let uploads = (0..<4).map { Data("upload \($0)\n".utf8) }
        try await LFSTestServer.withServer { server in
            for bytes in downloads { server.store(bytes, oid: hash(bytes)) }
            try await run(
                config: [
                    ("lfs.url", server.endpoint.absoluteString),
                    ("lfs.concurrenttransfers", "4")
                ],
                sessionConfiguration: .ephemeral
            ) { client, store, directory in
                try await queue(client, store).transfer(downloads.map { bytes in
                    LFSBatchObject(oid: hash(bytes), size: Int64(bytes.count))
                })
                for bytes in downloads {
                    let stored = try Data(contentsOf: store.objectPathname(hash(bytes)))
                    #expect(stored == bytes)
                }
                let gets = server.requests().filter { $0.method == "GET" && $0.status == 200 }
                #expect(gets.count == downloads.count)
                for bytes in downloads {
                    let get = try #require(gets.first { $0.path == "/objects/\(hash(bytes))" })
                    #expect(get.responseBody == bytes)
                }

                var files: [(Data, URL)] = []
                for (index, bytes) in uploads.enumerated() {
                    let file = directory.appendingPathComponent("upload-\(index)")
                    try bytes.write(to: file)
                    files.append((bytes, file))
                }
                try await queue(client, store, .upload).transfer(files.map { bytes, file in
                    LFSBatchObject(oid: hash(bytes), size: Int64(bytes.count), path: file.path)
                })
                for (bytes, _) in files {
                    #expect(server.bytes(for: hash(bytes)) == bytes)
                }
                let puts = server.requests().filter { $0.method == "PUT" && $0.status == 200 }
                #expect(puts.count == uploads.count)
                for (bytes, _) in files {
                    let put = try #require(puts.first { $0.path == "/objects/\(hash(bytes))" })
                    #expect(put.requestBody == bytes)
                }
            }
        }
    }

    @Test("retry exhaustion returns only the server's JSON message")
    func serverRetryExhaustion() async throws {
        let body = Data(#"{"message":"Server error"}"#.utf8)
        try await LFSTestServer.withServer { server in
            server.inject(.repeatingServerError)
            try await run(
                config: [
                    ("lfs.url", server.endpoint.absoluteString),
                    ("lfs.transfer.maxretries", "1")
                ],
                sessionConfiguration: .ephemeral
            ) { client, store, _ in
                await #expect(throws: LFSClientError("Server error")) {
                    try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: Int64(data.count))])
                }
            }
            let errors = server.requests().filter { $0.responseBody == body }
            #expect(server.requests().count == 2)
            #expect(errors.count == 2)
            #expect(errors.allSatisfy { $0.status == 500 })
        }
    }

    @Test("a corrupt download is rejected and is absent from objects")
    func corruptServerDownload() async throws {
        try await LFSTestServer.withServer { server in
            server.store(data, oid: oid)
            server.inject(.wrongSHA256(oid: oid))
            try await run(
                config: [("lfs.url", server.endpoint.absoluteString)],
                sessionConfiguration: .ephemeral
            ) { client, store, _ in
                do {
                    try await queue(client, store).transfer([LFSBatchObject(oid: oid, size: Int64(data.count))])
                    Issue.record("corrupt download succeeded")
                } catch {
                    let part = store.incompleteDirectory.appendingPathComponent(oid + ".part")
                    let saved = try Data(contentsOf: part)
                    let expected = "expected OID \(oid), got \(hash(saved)) after \(saved.count) bytes written"
                    #expect(String(describing: error) == expected)
                    #expect(saved != data)
                }
                #expect(!FileManager.default.fileExists(atPath: store.objectPathname(oid).path))
            }
            let gets = server.requests().filter { $0.method == "GET" }
            #expect(gets.count == 1)
            #expect(gets.first?.status == 200)
            #expect(gets.first?.fault == "sha256")
        }
    }

    @Test("an upload the server already has is skipped")
    func uploadAlreadyPresent() async throws {
        try await LFSTestServer.withServer { server in
            server.store(data, oid: oid)
            try await run(
                config: [("lfs.url", server.endpoint.absoluteString)],
                sessionConfiguration: .ephemeral
            ) { client, store, directory in
                let file = directory.appendingPathComponent("file")
                try data.write(to: file)
                try await queue(client, store, .upload).transfer([
                    LFSBatchObject(oid: oid, size: Int64(data.count), path: file.path)
                ])
            }
            #expect(!server.requests().contains { $0.method == "PUT" })
            #expect(server.bytes(for: oid) == data)
        }
    }
}
