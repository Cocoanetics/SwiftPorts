import Foundation
import ShellKit

/// Internal seams for deterministic retry/expiration tests and output capture.
/// `stdout` takes the progress text git-lfs's `tasklog` writes while the
/// command runs, so it reaches the shell as it happens.
struct LFSTransferEnvironment: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
    var stderr: @Sendable (String) -> Void = { LFSStandardError.write($0) }
    var stdout: @Sendable (String) -> Void = { Shell.current.stdout.write(Data($0.utf8)) }
}
