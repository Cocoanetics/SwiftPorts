import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(Bionic)
import Bionic
#endif

/// Lightweight TTY + colour-capability detection. Mirrors what gh does
/// in `pkg/iostreams/iostreams.go` — without the colour scheme zoo.
public enum TTY {
    /// True when stdout is attached to a terminal. We hit `isatty` with
    /// the raw `STDOUT_FILENO` integer (1) instead of `fileno(stdout)`
    /// — the `stdout` FILE* is a non-Sendable global on Linux and
    /// trips Swift 6.2 strict concurrency.
    ///
    /// iOS / tvOS / watchOS / visionOS apps don't have a terminal at
    /// all; `isatty` on the simulator surprisingly returns `true` (the
    /// xctest harness leaves stdout connected to a tty-shaped fd), so
    /// short-circuit those platforms to `false`.
    public static var isStdoutTTY: Bool {
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return false
#else
        return isatty(1) != 0
#endif
    }

    /// True when stderr is attached to a terminal. Same rationale as
    /// `isStdoutTTY` — uses the raw `STDERR_FILENO` integer (2).
    public static var isStderrTTY: Bool {
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return false
#else
        return isatty(2) != 0
#endif
    }

    /// True when colour escape codes should be emitted on stdout.
    /// Honors `NO_COLOR` (kill switch), `CLICOLOR_FORCE` (force-on),
    /// and otherwise gates on stdout-is-a-TTY.
    public static var isStdoutColorEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        if let v = env["NO_COLOR"], !v.isEmpty { return false }
        if let v = env["CLICOLOR_FORCE"], !v.isEmpty, v != "0" { return true }
        return isStdoutTTY
    }
}
