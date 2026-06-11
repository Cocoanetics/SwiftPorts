// Lz4Kit is available wherever Apple's Compression framework or
// system liblz4 is — every Apple platform plus Linux / Windows.
// Android stays gated out (no NDK liblz4, no Compression).
#if canImport(Compression) || os(Linux) || os(Windows)

import ArgumentParser
import Foundation
import Lz4Kit
import ShellKit

public enum Lz4Mode: Sendable {
    case compress
    case decompress
}

/// `lz4 [options] [file...]` — compress files (default) or
/// decompress with `-d`. Reads from stdin / writes to stdout when
/// no files are given.
public struct Lz4: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "lz4",
        abstract: "Compress files with LZ4 (frame format).",
        discussion: """
        With no files (or `-`), reads stdin and writes to stdout.
        With files, each <file> becomes <file>.lz4 and the original
        is removed unless -k is given. Use `-d` (or run as `unlz4`)
        to decompress.

        Output is the standard `.lz4` v1.6.x frame format —
        compatible with the upstream `lz4(1)` reference tool.
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

    // -1..-9: silently accepted for compatibility. We only expose
    // the default LZ4 fast level today; tuning lands when somebody
    // wires LZ4HC into the engine.
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
        try await Lz4Engine.run(
            mode: decompress ? .decompress : .compress,
            stdout: stdout,
            keep: keep,
            force: force,
            quiet: quiet,
            verbose: verbose,
            files: files)
    }
}

/// `unlz4 [options] [file...]` — equivalent to `lz4 -d`.
public struct Unlz4: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unlz4",
        abstract: "Decompress LZ4-compressed files."
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
        try await Lz4Engine.run(
            mode: .decompress,
            stdout: stdout,
            keep: keep,
            force: force,
            quiet: quiet,
            verbose: verbose,
            files: files)
    }
}

/// `lz4cat [file...]` — decompress to stdout. = `lz4 -dc`.
public struct Lz4cat: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "lz4cat",
        abstract: "Concatenate decompressed LZ4 files to stdout."
    )

    @Flag(name: [.customShort("f"), .long],
          help: "Force read even if input doesn't look LZ4-framed.")
    public var force: Bool = false

    @Argument(parsing: .remaining,
              help: "Files to decompress. '-' or no files = stdin.")
    public var files: [String] = []

    public init() {}

    public func run() async throws {
        try await Lz4Engine.run(
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

enum Lz4Engine {
    static func run(
        mode: Lz4Mode,
        stdout: Bool,
        keep: Bool,
        force: Bool,
        quiet: Bool,
        verbose: Bool,
        files: [String]
    ) async throws {
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
                    result = try await Lz4Kit.Lz4.compressFile(
                        at: url, keepInput: keep, overwrite: force)
                case .decompress:
                    result = try await Lz4Kit.Lz4.decompressFile(
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

    private static func processStdin(mode: Lz4Mode) async throws {
        let input = await Shell.current.stdin.readAllData()
        let output: Data
        switch mode {
        case .compress:   output = try await Lz4Kit.Lz4.compress(input)
        case .decompress: output = try await Lz4Kit.Lz4.decompress(input)
        }
        Shell.current.stdout.write(output)
    }

    private static func emitFileToStdout(url: URL, mode: Lz4Mode) async throws {
        try await Shell.authorize(url)
        let bytes = try Data(contentsOf: url)
        let output: Data
        switch mode {
        case .compress:   output = try await Lz4Kit.Lz4.compress(bytes)
        case .decompress: output = try await Lz4Kit.Lz4.decompress(bytes)
        }
        Shell.current.stdout.write(output)
    }
}

#endif // platform gate
