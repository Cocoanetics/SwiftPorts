import Foundation
import ShellKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#endif

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
    /// The terminal columns progress lines are padded to, asked for each line.
    var terminalWidth: @Sendable () -> Int = LFSTransferEnvironment.stdoutColumns

    /// `tasklog.NewLogger`'s `widthFn`: `ts.GetSize()` reads stdout's window
    /// size, and is 80 when that fails.
    static func stdoutColumns() -> Int {
        #if os(Windows)
        return 80
        #else
        var size = winsize()
        #if os(Linux) || os(Android)
        guard ioctl(1, UInt(TIOCGWINSZ), &size) == 0 else { return 80 }
        #else
        guard ioctl(1, TIOCGWINSZ, &size) == 0 else { return 80 }
        #endif
        return Int(size.ws_col)
        #endif
    }
}
