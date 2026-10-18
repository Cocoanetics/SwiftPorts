import ArgumentParser
import ShellKit
import Foundation
import SwiftGit

/// Exit non-zero with a custom stderr message — mirrors real git's
/// behaviour where errors are always printed to stderr with a specific
/// prefix (`error: …`, `fatal: …`, `hint: …`) and a stable exit code.
///
/// Use ``CLIError/stderr(_:exitCode:)`` instead of `throw CommandError`
/// when the wording matters; ArgumentParser's default formatter would
/// otherwise prefix our messages with `Error: `.
///
/// In-process (a shell embedding `git`, through ShellKit's
/// `Shell.parsableCommand`), it's a ShellKit `CommandFailure`: the shell
/// prints the lines as they are and exits with ``exitCode``, as git does.
/// Standalone-CLI callers go through ``emitAndExit()``. `LocalizedError`
/// keeps any other path from dumping the struct.
public struct CLIError: Error, LocalizedError, CommandFailure {
    public let lines: [String]
    public let exitCode: Int32

    public static func stderr(_ message: String, exitCode: Int32 = 1) -> CLIError {
        CLIError(lines: [message], exitCode: exitCode)
    }

    public static func stderr(_ lines: [String], exitCode: Int32 = 1) -> CLIError {
        CLIError(lines: lines, exitCode: exitCode)
    }

    public var errorDescription: String? {
        lines.joined(separator: "\n")
    }

    public var diagnostic: String {
        lines.map { $0 + "\n" }.joined()
    }

    public var exitStatus: ShellKit.ExitStatus {
        ShellKit.ExitStatus(exitCode)
    }
}

extension CLIError {
    /// git's words, and exit status, for a URL no transport handles.
    init(_ error: UnsupportedTransportError) {
        self.init(lines: error.lines, exitCode: 128)
    }

    /// Print every line to stderr and exit. Subcommands call this from
    /// `run()` via a top-level catch in `Entry.swift` so the exit-code
    /// path is uniform.
    public func emitAndExit() -> Never {
        let stderr = Shell.current.stderr
        for line in lines {
            if let data = (line + "\n").data(using: .utf8) {
                stderr.write(data)
            }
        }
        exit(exitCode)
    }
}
