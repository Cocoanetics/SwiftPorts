import Foundation

/// Internal seams for deterministic retry/expiration tests and stderr capture.
struct LFSTransferEnvironment: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
    var stderr: @Sendable (String) -> Void = { LFSStandardError.write($0) }
}
