import ShellKit

/// The shellkit-installable face of SwiftPorts' `sqlite3` shell port — the
/// "shellkit version" that sits alongside the standalone `sqlite3` executable
/// (the "macOS CLI version", `Sqlite3Command` + the `sqlite3` target).
///
/// It bridges ``Sqlite3Executable`` (the ArgumentParser-free argv parser /
/// dot-command / REPL driver) to ShellKit's ``Command`` protocol. Because it
/// carries no ArgumentParser dependency it builds and runs on every platform
/// — Android included, where the ArgumentParser-based command surface is
/// dropped — so an embedder can install a working `sqlite3` everywhere.
///
/// Its only dependencies are ShellKit (the ``Command`` base + ``Shell/current``
/// IO) and the in-package ``Sqlite3Executable`` engine. It does **not** depend
/// on any shell host (e.g. SwiftBash); a host merely installs it. The driver
/// reads / writes through ``Shell/current`` and resolves + authorizes
/// database / `.read` / `.backup` paths through the host sandbox, so the
/// command participates fully in pipes / redirection / `$(...)` capture.
public struct Sqlite3Builtin: Command {

    public init() {}

    public let name = "sqlite3"

    public func run(_ argv: [String]) async throws -> ExitStatus {
        // `Sqlite3Executable` expects argv WITHOUT the command name, per the
        // `execve` convention — the same handoff the standalone executable
        // makes. Everything else is passed through verbatim: the driver does
        // SQLite's single-dash long-option parsing (`-csv`, `-header`,
        // `-separator X`, …), `--version` / `--help`, dot-command dispatch,
        // and the REPL. No flag is intercepted here, so the builtin behaves
        // identically to `sqlite3` run standalone.
        let code = try await Sqlite3Executable.run(
            argv: Array(argv.dropFirst()),
            stdin: Shell.current.stdin,
            stdout: Shell.current.stdout,
            stderr: Shell.current.stderr)
        return ExitStatus(code)
    }
}
