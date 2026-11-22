import Foundation
import ShellKit
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
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
    var terminalWidth: @Sendable () -> Int = LFSTransferEnvironment.terminalColumns

    /// What `tasklog.Logger` pads each line to: `widthFn` on a terminal,
    /// 80 off one, where `ts.GetSize()` fails.
    func lineWidth(terminal: Bool) -> @Sendable () -> Int {
        if terminal { return terminalWidth }
        return { 80 }
    }

    /// `tasklog.NewLogger`'s `widthFn`: `ts.GetSize()` reads the window size
    /// of git-lfs's stdout, and is 80 when that fails. git-lfs's stdout is
    /// ours, except for the pre-push hook git runs, whose stdout git sends to
    /// its stderr; callers that found stderr to be the terminal are measured
    /// there when stdout is not one. On Windows `ts` takes the console
    /// window's `Right` edge as its columns, as unsigned.
    static func terminalColumns() -> Int {
        #if os(Windows)
        for handle in [STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
            var info = CONSOLE_SCREEN_BUFFER_INFO()
            if GetConsoleScreenBufferInfo(GetStdHandle(handle), &info) {
                return Int(UInt16(bitPattern: info.srWindow.Right))
            }
        }
        return 80
        #else
        for descriptor: Int32 in [1, 2] {
            var size = winsize()
            #if os(Linux) || os(Android)
            let status = ioctl(descriptor, UInt(TIOCGWINSZ), &size)
            #else
            let status = ioctl(descriptor, TIOCGWINSZ, &size)
            #endif
            if status == 0 { return Int(size.ws_col) }
        }
        return 80
        #endif
    }
}
