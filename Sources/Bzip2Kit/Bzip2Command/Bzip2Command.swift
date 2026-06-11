// Bzip2Kit's engine is only available where libbz2 is — see the
// platform gate in Sources/Bzip2Kit/Lib/Bzip2.swift. Mirror it here
// so the iOS / tvOS / watchOS / visionOS framework build doesn't
// reference symbols that don't exist on those platforms.
#if os(macOS) || os(Linux) || os(Windows)
import ArgumentParser
import Foundation
import Bzip2Kit
import ShellKit

/// Mode shared by `bzip2` / `bunzip2` / `bzcat` — the same engine
/// dispatched by argv[0]. We expose three `AsyncParsableCommand`
/// types so each binary has its own help / defaults; they all funnel
/// through `Bzip2Engine` below.
public enum Bzip2Mode: Sendable {
    case compress
    case decompress
}

/// `bzip2 [options] [file...]` — compress files (default) or
/// decompress with `-d`. Reads from stdin / writes to stdout when
/// no files are given.
public struct Bzip2: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "bzip2",
        abstract: "Compress files with bzip2.",
        discussion: """
        With no files (or `-`), reads stdin and writes to stdout.
        With files, each <file> becomes <file>.bz2 and the original is
        removed unless -k is given. Use `-d` (or run as `bunzip2`) to
        decompress.
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

    // -1..-9: silently accepted for compatibility. libbz2 picks the
    // configured default (9 = best); we don't expose runtime tuning.
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
        try await Bzip2Engine.run(
            mode: decompress ? .decompress : .compress,
            stdout: stdout,
            keep: keep,
            force: force,
            quiet: quiet,
            verbose: verbose,
            files: files)
    }
}

/// `bunzip2 [options] [file...]` — equivalent to `bzip2 -d`.
public struct Bunzip2: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "bunzip2",
        abstract: "Decompress bzip2-compressed files."
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
        try await Bzip2Engine.run(
            mode: .decompress,
            stdout: stdout,
            keep: keep,
            force: force,
            quiet: quiet,
            verbose: verbose,
            files: files)
    }
}

/// `bzcat [file...]` — decompress to stdout. = `bzip2 -dc`.
public struct Bzcat: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "bzcat",
        abstract: "Concatenate decompressed bzip2 files to stdout."
    )

    @Flag(name: [.customShort("f"), .long],
          help: "Force read even if input doesn't look bzip2'd.")
    public var force: Bool = false

    @Argument(parsing: .remaining,
              help: "Files to decompress. '-' or no files = stdin.")
    public var files: [String] = []

    public init() {}

    public func run() async throws {
        try await Bzip2Engine.run(
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

enum Bzip2Engine {
    static func run(
        mode: Bzip2Mode,
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
                    result = try await Bzip2Kit.Bzip2.compressFile(
                        at: url, keepInput: keep, overwrite: force)
                case .decompress:
                    result = try await Bzip2Kit.Bzip2.decompressFile(
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

    private static func processStdin(mode: Bzip2Mode) async throws {
        let input = await Shell.current.stdin.readAllData()
        let output: Data
        switch mode {
        case .compress:   output = try await Bzip2Kit.Bzip2.compress(input)
        case .decompress: output = try await Bzip2Kit.Bzip2.decompress(input)
        }
        Shell.current.stdout.write(output)
    }

    private static func emitFileToStdout(url: URL, mode: Bzip2Mode) async throws {
        try await Shell.authorize(url)
        let bytes = try Data(contentsOf: url)
        let output: Data
        switch mode {
        case .compress:   output = try await Bzip2Kit.Bzip2.compress(bytes)
        case .decompress: output = try await Bzip2Kit.Bzip2.decompress(bytes)
        }
        Shell.current.stdout.write(output)
    }
}

#endif // platform gate
