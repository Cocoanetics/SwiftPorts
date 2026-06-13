import ShellKit
import ShellCommandKit

import Bzip2Command
import FdCommand
import GhCommand
import GitCommand
import GlabCommand
import GzipCommand
import JqCommand
import Lz4Command
import RgCommand
import TarCommand
import UnzipCommand
import XzCommand
import ZipCommand
import ZstdCommand

/// SwiftPorts' CLI ports, vended as ready-to-install ShellKit ``Command``s.
///
/// Each port has two faces: a standalone macOS CLI executable (its `@main`
/// target — `jq`, `rg`, `git`, …) and a shellkit ``Command`` (vended here). A
/// host shell — e.g. SwiftBash — installs these as virtual bins; it does no
/// bridging of its own. The ArgumentParser → ``Command`` bridge is ShellKit's
/// own ``Shell/parsableCommand(_:)`` (in `ShellCommandKit`), so there's a
/// single bridge in the toolchain rather than a copy per host.
///
/// `sqlite3` is intentionally **not** in this list: its shellkit face is the
/// ArgumentParser-free `Sqlite3Shell.Sqlite3Builtin`, which also works on
/// Android — where this whole (ArgumentParser-backed) target is dropped.
/// Install that one separately and unconditionally.
public enum SwiftPortsCommands {

    /// The ArgumentParser-backed ports, each bridged to a ShellKit ``Command``
    /// (named from its `configuration.commandName`). The platform `#if` gates
    /// mirror the ones SwiftPorts' command targets carry, so every referenced
    /// type exists on the platform being compiled.
    public static var argumentParserCommands: [Command] {
        var commands: [Command] = [
            // JSON processor + forge CLIs (each with its own subcommand tree).
            Shell.parsableCommand(Jq.self),
            // gh rides an argv preprocessor: the bare `--json` rewrite
            // must hold on the embedded path too, where the standalone
            // entry (`GhCommand.main()`, which applies it) never runs.
            ArgvRewritingCommand(
                base: Shell.parsableCommand(GhCommand.self),
                rewrite: GhCommand.preprocess),
            Shell.parsableCommand(GlabCommand.self),
            // git rides an argv preprocessor too: the bare `--color`
            // rewrite must hold on the embedded path, where the standalone
            // entry (`Entry.main`, which applies it) never runs.
            ArgvRewritingCommand(
                base: Shell.parsableCommand(GitCommand.self),
                rewrite: GitCommand.preprocess),
            // search / find.
            Shell.parsableCommand(Rg.self),
            Shell.parsableCommand(FdCommand.self),
            // archive family.
            Shell.parsableCommand(TarCommand.self),
            Shell.parsableCommand(ZipCommand.self),
            Shell.parsableCommand(UnzipCommand.self),
            // gzip personalities — zlib is on every supported platform.
            Shell.parsableCommand(Gzip.self),
            Shell.parsableCommand(Gunzip.self),
            Shell.parsableCommand(Zcat.self),
        ]

        // bzip2 / zstd — libbz2 / libzstd aren't in the Apple-mobile SDKs, so
        // SwiftPorts gates these command types to desktop platforms.
        #if os(macOS) || os(Linux) || os(Windows)
        commands += [
            Shell.parsableCommand(Bzip2.self),
            Shell.parsableCommand(Bunzip2.self),
            Shell.parsableCommand(Bzcat.self),
            Shell.parsableCommand(Zstd.self),
            Shell.parsableCommand(Unzstd.self),
            Shell.parsableCommand(Zstdcat.self),
        ]
        #endif

        // xz / lz4 — Apple platforms back these via the Compression framework;
        // Linux / Windows via system liblzma / liblz4.
        #if canImport(Compression) || os(Linux) || os(Windows)
        commands += [
            Shell.parsableCommand(Xz.self),
            Shell.parsableCommand(Unxz.self),
            Shell.parsableCommand(Xzcat.self),
            Shell.parsableCommand(Lz4.self),
            Shell.parsableCommand(Unlz4.self),
            Shell.parsableCommand(Lz4cat.self),
        ]
        #endif

        return commands
    }
}

/// A ``Command`` decorator that rewrites the argument portion of argv
/// (everything after `argv[0]`, which stays the command name) before
/// delegating to the wrapped bridge. Lets a port share one argv
/// affordance — e.g. gh's bare `--json` rewrite — between its
/// standalone `main()` and its embedded face, instead of the fix
/// living only in the entry point embedders never run.
private struct ArgvRewritingCommand: Command {
    let base: Command
    let rewrite: @Sendable ([String]) -> [String]

    var name: String { base.name }

    func run(_ argv: [String]) async throws -> ExitStatus {
        guard let commandName = argv.first else {
            return try await base.run(argv)
        }
        return try await base.run(
            [commandName] + rewrite(Array(argv.dropFirst())))
    }
}
