import Foundation

/// Per-task standard-stream override.
///
/// CLI commands inside SwiftPorts read/write process IO through
/// ``Stdio/stdin`` / ``Stdio/stdout`` / ``Stdio/stderr`` instead of
/// `FileHandle.standardInput/Output/Error` directly. When
/// ``Stdio/current`` is `nil`, every static accessor falls back to
/// the corresponding `FileHandle.standard*`, preserving the
/// "regular CLI" behaviour. When an embedder sets it via
/// `Stdio.$current.withValue(...)`, the same code transparently
/// reads from / writes to the embedder's chosen `FileHandle`s.
///
/// Mirrors the shape of ``Sandbox/current``: a `@TaskLocal`-driven
/// `Sendable` value type with default-fallthrough on the read side,
/// so existing CLI invocations work unchanged and embedders opt in
/// per-task without touching command implementations.
///
/// ### Embedding example
///
/// SwiftBash, JavaScriptCore-backed runtimes, and any other shell
/// that wants to redirect a SwiftPorts CLI's stdio into its own
/// pipeline plumbing creates a ``Stdio`` with `Pipe()`-derived
/// `FileHandle`s and binds it for the duration of the command's
/// `run()`:
///
/// ```swift
/// let inPipe  = Pipe()   // shell writes to inPipe.fileHandleForWriting,
///                        // CLI reads from inPipe.fileHandleForReading
/// let outPipe = Pipe()   // CLI writes to outPipe.fileHandleForWriting,
///                        // shell reads from outPipe.fileHandleForReading
/// let errPipe = Pipe()
///
/// let stdio = Stdio(
///     stdin:  inPipe.fileHandleForReading,
///     stdout: outPipe.fileHandleForWriting,
///     stderr: errPipe.fileHandleForWriting)
///
/// try await Stdio.$current.withValue(stdio) {
///     try await someParsableCommand.run()
/// }
/// ```
///
/// Inside `run()`, every `Stdio.stdout.write(...)` ends up in
/// `outPipe`, and every `Stdio.stdin.readDataToEndOfFile()` reads
/// what the shell pushed into `inPipe`. The pipe endpoints are real
/// OS pipes so the bridge works the same whether the consumer is
/// SwiftBash, swift-js, or any other host.
public struct Stdio: Sendable {

    /// The active stdio override for the current Task scope, or
    /// `nil` if no override is in effect. Set via
    /// `Stdio.$current.withValue(_:)`.
    @TaskLocal public static var current: Stdio?

    public let stdin: FileHandle
    public let stdout: FileHandle
    public let stderr: FileHandle

    public init(stdin: FileHandle = FileHandle.standardInput,
                stdout: FileHandle = FileHandle.standardOutput,
                stderr: FileHandle = FileHandle.standardError)
    {
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
    }

    // MARK: Static accessors (default-fallthrough)

    /// Effective stdin: the embedder override if set, else the
    /// host process's `FileHandle.standardInput`.
    public static var stdin: FileHandle {
        current?.stdin ?? FileHandle.standardInput
    }

    /// Effective stdout: the embedder override if set, else the
    /// host process's `FileHandle.standardOutput`.
    public static var stdout: FileHandle {
        current?.stdout ?? FileHandle.standardOutput
    }

    /// Effective stderr: the embedder override if set, else the
    /// host process's `FileHandle.standardError`.
    public static var stderr: FileHandle {
        current?.stderr ?? FileHandle.standardError
    }

    // MARK: print(_:) replacement
    //
    // Swift's stdlib `print(_:separator:terminator:)` writes to
    // `FILE *stdout` (fd 1) directly, bypassing `FileHandle.standardOutput`
    // — and therefore bypassing this override. CLI bodies that want
    // their output to participate in a host's pipeline must use
    // ``Stdio/print(_:separator:terminator:)`` instead.
    //
    // The signature mirrors the stdlib so existing call sites
    // migrate by replacing `print(` with `Stdio.print(`.

    /// Drop-in replacement for stdlib `print(_:separator:terminator:)`
    /// that routes through ``Stdio/stdout`` and therefore honours
    /// ``Stdio/current``.
    ///
    /// Use this everywhere a CLI body would otherwise call the
    /// stdlib `print`. Stdlib `print` is enforced-banned in
    /// `Sources/` by `NoStdlibPrintInSourcesTests`, the same way
    /// ambient FS/env APIs are banned.
    public static func print(_ items: Any...,
                             separator: String = " ",
                             terminator: String = "\n")
    {
        var rendered = ""
        var first = true
        for item in items {
            if !first { rendered += separator }
            rendered += "\(item)"
            first = false
        }
        rendered += terminator
        stdout.write(Data(rendered.utf8))
    }
}
