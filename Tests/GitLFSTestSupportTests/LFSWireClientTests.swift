import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("LFSWireClientTests")
struct LFSWireClientTests {
    @Test("wire sessions are invalidated before leaving a test, including on error", arguments: [false, true])
    func sessionLifetime(throwFromBody: Bool) async throws {
        var previous: LFSWireClient?
        var lifetime: LFSWireSessionDelegate?
        let run = {
            try await LFSWireClient.withServer { server, client in
                previous = client
                lifetime = try #require(client.session.delegate as? LFSWireSessionDelegate)
                #expect(lifetime?.isInvalidated == false)
                let response = try await client.get(server.endpoint.absoluteString + "/missing")
                #expect(response.status == 404)
                if throwFromBody { throw URLError(.cancelled) }
            }
        }
        if throwFromBody {
            await #expect(throws: URLError(.cancelled)) { try await run() }
        } else {
            try await run()
        }
        let finished = try #require(lifetime)
        #expect(finished.isInvalidated)
        let first = try #require(previous)
        try await LFSWireClient.withServer { server, client in
            #expect(client.session !== first.session)
            #expect(client.session.delegate !== finished)
            let response = try await client.get(server.endpoint.absoluteString + "/missing")
            #expect(response.status == 404)
        }
    }
}
