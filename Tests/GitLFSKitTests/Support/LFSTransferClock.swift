import Foundation
@testable import GitLFSKit

final class LFSTransferClock: Sendable {
    private let state = TransferTestLock((Date(), [TimeInterval](), ""))

    var delays: [TimeInterval] { state.withLock { $0.1 } }
    var stderr: String { state.withLock { $0.2 } }

    var environment: LFSTransferEnvironment {
        LFSTransferEnvironment(
            now: { self.state.withLock { $0.0 } },
            sleep: { seconds in self.state.withLock { $0.0 += seconds; $0.1.append(seconds) } },
            stderr: { text in self.state.withLock { $0.2 += text } })
    }
}
