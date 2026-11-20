import Foundation
import GitLFSTestSupport
import Testing

extension LFSTestServerTests {
    @Test("an injected 401 is on the wire and in the request log")
    func injectedUnauthorized() async throws {
        try await LFSTestServer.withServer { server in
            server.inject(.unauthorized)
            let response = try await LFSWireClient.postBatch(
                server, operation: "download", objects: [(oid: "abc", size: 1)]
            )
            try expectFault(server, response: response, method: "POST", status: 401, fault: "401")
            let message = try JSONDecoder().decode(ErrorEnvelope.self, from: response.body).message
            #expect(message == "Unauthorized")
            #expect(server.requests().last?.path == "/objects/batch")
        }
    }

    @Test(
        "an injected per-object error is on the wire and in the request log",
        arguments: [404, 410, 422]
    )
    func injectedObjectError(code: Int) async throws {
        let oid = String(repeating: "ab", count: 32)
        try await LFSTestServer.withServer { server in
            server.inject(.objectStatus(oid: oid, code: code))
            let response = try await LFSWireClient.postBatch(
                server, operation: "download", objects: [(oid: oid, size: 4)]
            )
            #expect(response.status == 200)
            try expectFault(server, response: response, method: "POST", status: 200, fault: String(code))
            let object = try #require(try LFSWireClient.document(response).object(oid))
            #expect(object.error?.code == code)
            #expect(object.actions == nil)
        }
    }

    @Test("an injected 429 carries Retry-After on the wire and in the request log")
    func injectedRetryAfter() async throws {
        try await LFSTestServer.withServer { server in
            server.inject(.tooManyRequests(retryAfter: "12"))
            let response = try await LFSWireClient.postBatch(
                server, operation: "upload", objects: [(oid: "abc", size: 1)]
            )
            try expectFault(server, response: response, method: "POST", status: 429, fault: "429")
            #expect(response.value("Retry-After") == "12")
            #expect(server.requests().last?.responseHeaders["retry-after"] == "12")
        }
    }

    @Test("a repeating server error answers later requests with the same JSON message")
    func injectedRepeatingServerError() async throws {
        try await LFSTestServer.withServer { server in
            server.inject(.repeatingServerError)
            for _ in 0..<2 {
                let response = try await LFSWireClient.postBatch(
                    server, operation: "download", objects: [(oid: "abc", size: 1)]
                )
                try expectFault(server, response: response, method: "POST", status: 500, fault: "500")
                let message = try JSONDecoder().decode(ErrorEnvelope.self, from: response.body).message
                #expect(message == "Server error")
            }
            #expect(server.requests().count == 2)
        }
    }

    @Test("an injected 5xx is on the wire and in the request log")
    func injectedServerError() async throws {
        try await LFSTestServer.withServer { server in
            server.inject(.serverError(503))
            let response = try await LFSWireClient.postBatch(
                server, operation: "download", objects: [(oid: "abc", size: 1)]
            )
            try expectFault(server, response: response, method: "POST", status: 503, fault: "503")
        }
    }

    @Test("an action can carry an expires_at that is already past")
    func injectedExpiredAction() async throws {
        let bytes = Data("expire\n".utf8)
        let oid = sha256Hex(bytes)
        try await LFSTestServer.withServer { server in
            server.inject(.expired(oid: oid))
            let response = try await LFSWireClient.postBatch(
                server, operation: "upload", objects: [(oid: oid, size: bytes.count)]
            )
            #expect(response.status == 200)
            try expectFault(server, response: response, method: "POST", status: 200, fault: "expired")
            let object = try #require(try LFSWireClient.document(response).object(oid))
            let upload = try #require(object.actions?["upload"])
            let verify = try #require(object.actions?["verify"])
            #expect(rfc3339(upload.expiresAt) ?? .distantFuture < Date())
            #expect(rfc3339(verify.expiresAt) ?? .distantFuture < Date())
        }
    }

    @Test("an injected download body can have the wrong size")
    func injectedWrongSize() async throws {
        let bytes = Data("hello\n".utf8)
        let oid = sha256Hex(bytes)
        try await LFSTestServer.withServer { server in
            server.store(bytes, oid: oid)
            server.inject(.wrongSize(oid: oid))
            let batch = try await LFSWireClient.postBatch(
                server, operation: "download", objects: [(oid: oid, size: bytes.count)]
            )
            let href = try #require(try LFSWireClient.document(batch).object(oid)?.actions?["download"]?.href)
            let response = try await LFSWireClient.get(href)
            #expect(response.status == 200)
            #expect(response.body.count != bytes.count)
            try expectFault(server, response: response, method: "GET", status: 200, fault: "size")
        }
    }

    @Test("an injected download body can have the wrong SHA-256")
    func injectedWrongSHA256() async throws {
        let bytes = Data("hello\n".utf8)
        let oid = sha256Hex(bytes)
        try await LFSTestServer.withServer { server in
            server.store(bytes, oid: oid)
            server.inject(.wrongSHA256(oid: oid))
            let batch = try await LFSWireClient.postBatch(
                server, operation: "download", objects: [(oid: oid, size: bytes.count)]
            )
            let href = try #require(try LFSWireClient.document(batch).object(oid)?.actions?["download"]?.href)
            let response = try await LFSWireClient.get(href)
            #expect(response.status == 200)
            #expect(response.body.count == bytes.count)
            #expect(sha256Hex(response.body) != oid)
            try expectFault(server, response: response, method: "GET", status: 200, fault: "sha256")
        }
    }
}

private func expectFault(
    _ server: LFSTestServer, response: WireBody, method: String, status: Int, fault: String
) throws {
    #expect(response.status == status)
    let entry = try #require(server.requests().last { request in
        request.method == method && request.status == status && request.fault == fault
    })
    #expect(entry.responseBody == response.body)
}
