import Foundation
import ShellKit

/// Internal seams for deterministic retry/expiration tests and output capture.
/// `stdout` takes the progress text git-lfs's `tasklog` writes while the
/// command runs, so it reaches the shell as it happens. Both sinks are the
/// shell current when the environment is created.
struct LFSTransferEnvironment: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }
    // `Shell.current` is task-local and URLSession delegate callbacks don't
    // inherit it, so each sink is bound when the environment is made.
    var stderr: @Sendable (String) -> Void = { [sink = Shell.current.stderr] in sink.write(Data($0.utf8)) }
    var stdout: @Sendable (String) -> Void = { [sink = Shell.current.stdout] in sink.write(Data($0.utf8)) }
}
