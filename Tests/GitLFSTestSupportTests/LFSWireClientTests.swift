import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("LFSWireClientTests")
struct LFSWireClientTests {
    @Test("parallel wire fixture teardown hands off to held transfers repeatedly")
    func parallelTransfersHandoff() async throws {
        // Exercise the exact fixture handoff seen in the Windows crash in every CI run.
        for _ in 0..<25 {
            try await LFSTestServerTests().parallelTransfers()
            try await LFSTestServerTests().heldTransfersOverlap()
        }
    }

    @Test("wire channels and event loops close before leaving a test, including on error", arguments: [false, true])
    func connectionLifetime(throwFromBody: Bool) async throws {
        var previous: LFSWireClient?
        let run = {
            try await LFSWireClient.withServer { server, client in
                previous = client
                #expect(!client.isShutdown)
                let response = try await client.get(server.endpoint.absoluteString + "/missing")
                #expect(response.status == 404)
                // The server keeps HTTP/1.1 connections alive. A completed response
                // alone must not let its client socket escape into fixture teardown.
                #expect(client.openConnectionCount == 0)
                if throwFromBody { throw URLError(.cancelled) }
            }
        }
        if throwFromBody {
            await #expect(throws: URLError(.cancelled)) { try await run() }
        } else {
            try await run()
        }
        let first = try #require(previous)
        #expect(first.isShutdown)
        #expect(first.openConnectionCount == 0)
        try await LFSWireClient.withServer { server, client in
            #expect(client !== first)
            let response = try await client.get(server.endpoint.absoluteString + "/missing")
            #expect(response.status == 404)
            #expect(client.openConnectionCount == 0)
        }
    }

    @Test("cancelling a held wire request waits for its socket to close")
    func cancelHeldRequest() async throws {
        try await LFSWireClient.withServer { server, client in
            let href = server.endpoint.absoluteString + "/objects/missing"
            await server.holdObjectTransfers(untilInFlight: 2, timeout: .seconds(5))
            _ = try await client.get(href) // The hold bypasses its first object transfer.
            let pending = Task { try await client.get(href) }
            let deadline = ContinuousClock.now + .seconds(2)
            while await server.peakObjectTransfers() == 0, ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(await server.peakObjectTransfers() == 1)
            #expect(client.openConnectionCount == 1)
            pending.cancel()
            await #expect(throws: CancellationError.self) { try await pending.value }
            #expect(client.openConnectionCount == 0)
        }
    }

    @Test("a failed connection leaves no wire socket or unresolved response")
    func connectionFailure() async throws {
        try await LFSWireClient.withServer { server, client in
            await server.shutdown()
            await #expect(throws: (any Error).self) {
                try await client.get(server.endpoint.absoluteString + "/missing")
            }
            #expect(client.openConnectionCount == 0)
        }
    }
}
