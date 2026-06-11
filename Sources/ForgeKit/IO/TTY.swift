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
#elseif os(Windows)
import WinSDK
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
#elseif os(Windows)
        // MSVC deprecated the POSIX-named `isatty` in favour of the
        // ISO-C-conformant `_isatty`. Same signature, no runtime
        // difference — silences the deprecation warning.
        return _isatty(1) != 0
#else
        return isatty(1) != 0
#endif
    }

    /// True when stderr is attached to a terminal. Same rationale as
    /// `isStdoutTTY` — uses the raw `STDERR_FILENO` integer (2).
    public static var isStderrTTY: Bool {
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return false
#elseif os(Windows)
        return _isatty(2) != 0
#else
        return isatty(2) != 0
#endif
    }

    /// True when stdin is attached to a terminal — i.e. nothing is
    /// piped or redirected into the process. Tools like ripgrep gate
    /// "search cwd vs read stdin" on this.
    public static var isStdinTTY: Bool {
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return false
#elseif os(Windows)
        return _isatty(0) != 0
#else
        return isatty(0) != 0
#endif
    }

    /// True when stdin is connected to input worth *reading* — a
    /// regular file, FIFO/pipe, or (Unix) socket — as opposed to an
    /// interactive terminal or a character device like `/dev/null`.
    ///
    /// Mirrors ripgrep's `is_readable_stdin()`: tools that treat "no
    /// path argument" as "search the cwd" gate the stdin-vs-walk
    /// decision on this, not on `!isStdinTTY` — a GUI host or CI
    /// harness hands its children `/dev/null` (not a TTY, but not
    /// readable input either), and real rg walks the cwd there.
    /// Detection errors mean "not readable": when in doubt, walk —
    /// that also keeps a closed fd 0 out of the stdin-reading path.
    public static var isStdinReadable: Bool {
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        // No terminal — and fd 0 of the host process tells an embedded
        // shell nothing about its own pipeline. Walk-the-cwd is the
        // only sane default; an embedder that pipes into a command
        // does so through the bound shell's `InputSource`, not fd 0.
        return false
#elseif os(Windows)
        // Upstream (via winapi_util) asks GetFileType: a disk file or
        // a pipe is readable input; console (FILE_TYPE_CHAR) is not.
        if _isatty(0) != 0 { return false }
        guard let handle = GetStdHandle(STD_INPUT_HANDLE),
              handle != INVALID_HANDLE_VALUE else { return false }
        let type = GetFileType(handle)
        return type == DWORD(FILE_TYPE_DISK) || type == DWORD(FILE_TYPE_PIPE)
#else
        if isatty(0) != 0 { return false }
        var status = stat()
        guard fstat(0, &status) == 0 else { return false }
        switch status.st_mode & S_IFMT {
        case S_IFREG, S_IFIFO, S_IFSOCK:
            return true
        default:
            return false
        }
#endif
    }

    /// True when colour escape codes should be emitted on stdout.
    /// Honors `NO_COLOR` (kill switch), `CLICOLOR_FORCE` (force-on),
    /// and otherwise gates on stdout-is-a-TTY.
    public static var isStdoutColorEnabled: Bool {
        if let v = Shell.env("NO_COLOR"), !v.isEmpty { return false }
        if let v = Shell.env("CLICOLOR_FORCE"), !v.isEmpty, v != "0" { return true }
        return isStdoutTTY
    }
}
