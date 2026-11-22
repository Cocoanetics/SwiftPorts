import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GitLFSTestSupport
import Testing

@Suite("Public Git LFS test-server consumer", .timeLimit(.minutes(1)))
struct ServerConsumerTests {
    private static let bytes = Data("abc".utf8)
    private static let oid = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test("start binds an ephemeral loopback endpoint and exposes seeded objects")
    func startAndSeed() async throws {
        let server = try await LFSTestServer.start()
        do {
            #expect(server.endpoint.scheme == "http")
            #expect(server.endpoint.host == "127.0.0.1")
            #expect((1...65535).contains(server.port))
            #expect(server.endpoint.port == server.port)
            #expect(try TCPConnectionProbe.connects(port: server.port))
            server.store(Self.bytes, oid: Self.oid)
            #expect(server.bytes(for: Self.oid) == Self.bytes)
            try await LFSTestServer.withServer { other in
                #expect(other.port != server.port)
                #expect(other.bytes(for: Self.oid) == nil)
            }
            let (data, response) = try await Self.request(Self.objectURL(server))
            #expect(response.statusCode == 200)
            #expect(data == Self.bytes)
            let recorded = try #require(server.requests().last)
            #expect(recorded.method == "GET")
            #expect(recorded.path == "/objects/\(Self.oid)")
            #expect(recorded.responseBody == Self.bytes)
            await server.shutdown()
        } catch {
            await server.shutdown()
            throw error
        }
        // Explicit shutdown is idempotent; a fresh connection must be refused.
        await server.shutdown()
        #expect(try !TCPConnectionProbe.connects(port: server.port))
    }

    @Test("withServer shuts down after return and throw", arguments: [false, true])
    func scopedShutdown(throwFromBody: Bool) async throws {
        var captured: LFSTestServer?
        do {
            let port = try await LFSTestServer.withServer { server in
                captured = server
                #expect(try TCPConnectionProbe.connects(port: server.port))
                let (_, response) = try await Self.request(Self.objectURL(server))
                #expect(response.statusCode == 404)
                if throwFromBody { throw URLError(.cancelled) }
                return server.port
            }
            #expect(!throwFromBody)
            #expect(port == captured?.port)
        } catch let error as URLError where throwFromBody && error.code == .cancelled {
            // The body error survives cleanup.
        }
        let server = try #require(captured)
        #expect(try !TCPConnectionProbe.connects(port: server.port))
    }

    @Test("an injected PUT fault is recorded, prevents storage, and is consumed")
    func failedUpload() async throws {
        try await LFSTestServer.withServer { server in
            let url = Self.objectURL(server)
            server.inject(.putStatus(oid: Self.oid, code: 422))
            let (_, rejected) = try await Self.request(url, method: "PUT", body: Self.bytes)
            #expect(rejected.statusCode == 422)
            #expect(server.bytes(for: Self.oid) == nil)
            let recorded = try #require(server.requests().last)
            #expect(recorded.method == "PUT")
            #expect(recorded.status == 422)
            #expect(recorded.fault == "422")
            #expect(recorded.requestBody == Self.bytes)

            let (_, accepted) = try await Self.request(url, method: "PUT", body: Self.bytes)
            #expect(accepted.statusCode == 200)
            #expect(server.bytes(for: Self.oid) == Self.bytes)
            #expect(server.requests().last?.fault == nil)
            let (downloaded, response) = try await Self.request(url)
            #expect(response.statusCode == 200)
            #expect(downloaded == Self.bytes)
        }
    }

    private static func objectURL(_ server: LFSTestServer) -> URL {
        server.endpoint.appendingPathComponent("objects/\(oid)")
    }

    private static func request(
        _ url: URL, method: String = "GET", body: Data? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        // HTTP behavior is checked separately from the TCP lifecycle probes.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }
}
