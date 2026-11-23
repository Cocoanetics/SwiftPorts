import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import GitLFSTestSupport

struct LFSHeldObjectRequestTests {
    @Test("receipt latches before observation and reports whether parking released the hold", arguments: [1, 2])
    func latchedReceipt(target: Int) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let core = LFSServerCore()
        let receipts = core.heldObjectRequests
        let bytes = Data("complete request body".utf8)
        do {
            try await loop.submit {
                core.armObjectHold(count: target, timeout: .seconds(10), loop: loop)
                // Preserve the primer bypass, then park the later request.
                #expect(core.beginObjectHold(method: "PUT", uri: "/objects/test") == .bypass)
                #expect(core.beginObjectHold(method: "PUT", uri: "/objects/test") == .hold)
                let response = loop.makePromise(of: Void.self)
                core.parkObjectHold(response, method: "PUT", uri: "/objects/test", body: bytes)
                core.releaseObjectHold()
            }.get()
            // Both publication and release precede iterator creation. The
            // immutable receipt must retain the earlier parked state.
            var iterator = receipts.makeAsyncIterator()
            let receipt = try #require(await iterator.next())
            #expect(receipt.method == "PUT")
            #expect(receipt.path == "/objects/test")
            #expect(receipt.requestBody == bytes)
            #expect(receipt.responseIsHeld == (target == 2))
            #expect(await iterator.next() == nil)
            try await group.shutdownGracefully()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    @Test("shutdown ends receipt observation when no request arrived")
    func shutdownWithoutReceipt() async throws {
        let server = try await LFSTestServer.start()
        let receipts = server.heldObjectRequests()
        await server.shutdown()
        var iterator = receipts.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}
