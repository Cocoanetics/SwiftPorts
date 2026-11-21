import Foundation
import Testing
@testable import GitLFSKit

extension LFSTransferQueueTests {
    @Test("an object is reported finished when its own transfer succeeds, before the batch ends")
    func completionPerObject() async throws {
        let other = Data("other".utf8)
        let otherOID = hash(other)
        let firstDone = LFSTransferSignal()
        let reportedEarly = TransferTestLock(false)
        LFSTransferURLProtocol.install { request in
            if request.url?.lastPathComponent == "batch" { return .batch(request) }
            if request.url?.lastPathComponent == otherOID {
                // Held until the first object's completion arrives, or five
                // seconds pass, which then release it either way.
                return LFSTransferReply(body: other, beforeResponse: {
                    let early = await withTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            await firstDone.wait()
                            return true
                        }
                        group.addTask {
                            try? await Task.sleep(for: .seconds(5))
                            await firstDone.signal()
                            return false
                        }
                        let first = await group.next() ?? false
                        group.cancelAll()
                        return first
                    }
                    reportedEarly.withLock { $0 = early }
                })
            }
            return LFSTransferReply(body: data)
        }
        try await run(config: [("lfs.concurrenttransfers", "2")]) { client, store, _ in
            let oid = oid
            let queue = LFSTransferQueue(
                client: client, store: store, direction: .download, remote: "", refName: "refs/heads/main",
                environment: LFSTransferEnvironment(),
                completion: { completion in
                    guard case .transferred(let object) = completion, object.oid == oid else { return }
                    Task { await firstDone.signal() }
                })
            try await queue.transfer([
                LFSBatchObject(oid: oid, size: Int64(data.count)), LFSBatchObject(oid: otherOID, size: 5)
            ])
        }
        #expect(reportedEarly.withLock { $0 })
    }
}
