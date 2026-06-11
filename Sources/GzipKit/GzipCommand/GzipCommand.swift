import ArgumentParser
import Foundation
import GzipKit
import ShellKit

/// Shared engine for `gzip`, `gunzip`, and `zcat` — they're the same
/// binary in upstream gzip, distinguished only by argv[0]. We model
/// them as three separate `AsyncParsableCommand`s with different
/// defaults for `decompress` and `stdout`, all delegating into
/// `GzipEngine.run` below.
public enum GzipMode: Sendable {
    case compress
    case decompress
}

/// `gzip [options] [file...]` — compress files (default) or decompress
/// with `-d`. Reads from stdin / writes to stdout when no files are
/// given.
public struct Gzip: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gzip",
        abstract: "Compress files with gzip.",
        discussion: """
        With no files, reads stdin and writes to stdout. With files,
        each <file> becomes <file>.gz and the original is removed
        unless -k is given. Use `-d` (or run as `gunzip`) to decompress.
        """
    )

    @Flag(name: [.customShort("d"), .long],
          help: "Decompress instead of compress.")
    public var decompress: Bool = false

    @Flag(name: [.customShort("c"), .long],
          help: "Write to stdout. Implies -k. Required when reading stdin.")
    public var stdout: Bool = false

    @Flag(name: [.customShort("k"), .long],
          help: "Keep input files (don't delete them).")
    public var keep: Bool = false

    @Flag(name: [.customShort("f"), .long],
          help: "Force overwrite of existing output files.")
    public var force: Bool = false

    @Flag(name: [.customShort("q"), .long], help: "Suppress warnings.")
    public var quiet: Bool = false

    @Flag(name: [.customShort("v"), .long],
          help: "Print per-file actions on stderr.")
    public var verbose: Bool = false

    // -1..-9: silently accepted for compatibility. libarchive picks the
    // default level; we don't expose runtime level tuning yet.
    @Flag(name: .customShort("1"), help: ArgumentHelp(visibility: .hidden))
    public var level1 = false
    @Flag(name: .customShort("2"), help: ArgumentHelp(visibility: .hidden))
    public var level2 = false
    @Flag(name: .customShort("3"), help: ArgumentHelp(visibility: .hidden))
    public var level3 = false
    @Flag(name: .customShort("4"), help: ArgumentHelp(visibility: .hidden))
    public var level4 = false
    @Flag(name: .customShort("5"), help: ArgumentHelp(visibility: .hidden))
    public var level5 = false
    @Flag(name: .customShort("6"), help: ArgumentHelp(visibility: .hidden))
    public var level6 = false
    @Flag(name: .customShort("7"), help: ArgumentHelp(visibility: .hidden))
    public var level7 = false
    @Flag(name: .customShort("8"), help: ArgumentHelp(visibility: .hidden))
    public var level8 = false
    @Flag(name: .customShort("9"), help: ArgumentHelp(visibility: .hidden))
    public var level9 = false

    @Argument(parsing: .remaining,
              help: "Files to (de)compress. '-' or no files = stdin.")
    public var files: [String] = []

    public init() {}

    public func run() async throws {
        try await GzipEngine.run(
            mode: decompress ? .decompress : .compress,
            stdout: stdout,
            keep: keep,
            force: force,
            quiet: quiet,
            verbose: verbose,
            files: files)
    }
}

/// `gunzip [options] [file...]` — equivalent to `gzip -d`.
public struct Gunzip: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "gunzip",
        abstract: "Decompress gzip-compressed files."
    )

    @Flag(name: [.customShort("c"), .long],
          help: "Write to stdout. Implies -k.")
    public var stdout: Bool = false

    @Flag(name: [.customShort("k"), .long],
          help: "Keep input files.")
    public var keep: Bool = false

    @Flag(name: [.customShort("f"), .long],
          help: "Force overwrite.")
    public var force: Bool = false

    @Flag(name: [.customShort("q"), .long], help: "Suppress warnings.")
    public var quiet: Bool = false

    @Flag(name: [.customShort("v"), .long],
          help: "Print per-file actions on stderr.")
    public var verbose: Bool = false

    @Argument(parsing: .remaining,
              help: "Files to decompress. '-' or no files = stdin.")
    public var files: [String] = []

    public init() {}

    public func run() async throws {
        try await GzipEngine.run(
            mode: .decompress,
            stdout: stdout,
            keep: keep,
            force: force,
            quiet: quiet,
            verbose: verbose,
            files: files)
    }
}

/// `zcat [file...]` — decompress gzip files to stdout. Equivalent to
/// `gzip -dc` / `gunzip -c`. Doesn't remove input.
public struct Zcat: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "zcat",
        abstract: "Concatenate decompressed gzip files to stdout."
    )

    @Flag(name: [.customShort("f"), .long],
          help: "Force read even if input doesn't look gzipped.")
    public var force: Bool = false

    @Argument(parsing: .remaining,
              help: "Files to decompress. '-' or no files = stdin.")
    public var files: [String] = []

    public init() {}

    public func run() async throws {
        try await GzipEngine.run(
            mode: .decompress,
            stdout: true,
            keep: true,
            force: force,
            quiet: false,
            verbose: false,
            files: files)
    }
}

// MARK: - Engine

enum GzipEngine {
    static func run(
        mode: GzipMode,
        stdout: Bool,
        keep: Bool,
        force: Bool,
        quiet: Bool,
        verbose: Bool,
        files: [String]
    ) async throws {
        // No files (or "-") → stream stdin to stdout.
        if files.isEmpty || files == ["-"] {
            try await processStdin(mode: mode)
            return
        }

        for file in files {
            try Task.checkCancellation()
            if file == "-" {
                try await processStdin(mode: mode)
                continue
            }
            let url = Shell.resolve(file)
            if stdout {
                try await emitFileToStdout(url: url, mode: mode)
                if verbose {
                    Shell.current.stderr.write(
                        Data("\(file) -> stdout\n".utf8))
                }
            } else {
                let result: URL
                switch mode {
                case .compress:
                    result = try await GzipKit.Gzip.compressFile(
                        at: url, keepInput: keep, overwrite: force)
                case .decompress:
                    result = try await GzipKit.Gzip.decompressFile(
                        at: url, keepInput: keep, overwrite: force)
                }
                if verbose {
                    Shell.current.stderr.write(
                        // Fold the resolved (host) output path back to the
                        // script-visible spelling under a path-mapped
                        // sandbox (a no-op otherwise).
                        Data("\(file) -> \(Shell.displayPath(for: result))\n".utf8))
                }
            }
        }
    }

    private static func processStdin(mode: GzipMode) async throws {
        let input = await Shell.current.stdin.readAllData()
        let output: Data
        switch mode {
        case .compress:   output = try await GzipKit.Gzip.compress(input)
        case .decompress: output = try await GzipKit.Gzip.decompress(input)
        }
        Shell.current.stdout.write(output)
    }

    private static func emitFileToStdout(url: URL, mode: GzipMode) async throws {
        try await Shell.authorize(url)
        let bytes = try Data(contentsOf: url)
        let output: Data
        switch mode {
        case .compress:   output = try await GzipKit.Gzip.compress(bytes)
        case .decompress: output = try await GzipKit.Gzip.decompress(bytes)
        }
        Shell.current.stdout.write(output)
    }
}
