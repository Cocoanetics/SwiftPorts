import ArgumentParser
import Sandbox
import Foundation

/// Exit non-zero with a custom stderr message — mirrors real git's
/// behaviour where errors are always printed to stderr with a specific
/// prefix (`error: …`, `fatal: …`, `hint: …`) and a stable exit code.
///
/// Use ``CLIError/stderr(_:exitCode:)`` instead of `throw CommandError`
/// when the wording matters; ArgumentParser's default formatter would
/// otherwise prefix our messages with `Error: `.
public struct CLIError: Error {
    public let lines: [String]
    public let exitCode: Int32

    public static func stderr(_ message: String, exitCode: Int32 = 1) -> CLIError {
        CLIError(lines: [message], exitCode: exitCode)
    }

    public static func stderr(_ lines: [String], exitCode: Int32 = 1) -> CLIError {
        CLIError(lines: lines, exitCode: exitCode)
    }
}

extension CLIError {
    /// Print every line to stderr and exit. Subcommands call this from
    /// `run()` via a top-level catch in `Entry.swift` so the exit-code
    /// path is uniform.
    public func emitAndExit() -> Never {
        let stderr = Stdio.stderr
        for line in lines {
            if let data = (line + "\n").data(using: .utf8) {
                try? stderr.write(contentsOf: data)
            }
        }
        exit(exitCode)
    }
}
