import Foundation
import Testing
@testable import ForgeKit

struct BlockingBridgeTests {
    @Test("cancellation disposes a successful resource result before throwing", arguments: [false, true])
    func resourceOwnership(cancel: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("temporary")
        let cancellation = BlockingBridgeCancellation()
        let acquire: @Sendable () async throws -> URL = {
            try Data().write(to: file)
            // Deterministically cancel after acquiring the resource, before
            // the waiting caller can take ownership of the successful result.
            if cancel { cancellation.cancel() }
            return file
        }
        let discard: @Sendable (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }
        if cancel {
            #expect(throws: CancellationError.self) {
                try BlockingBridge.runBlocking(cancellation: cancellation, onDiscard: discard, acquire)
            }
            #expect(!FileManager.default.fileExists(atPath: file.path))
        } else {
            let result = try BlockingBridge.runBlocking(cancellation: cancellation, onDiscard: discard, acquire)
            #expect(result == file)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }
}
