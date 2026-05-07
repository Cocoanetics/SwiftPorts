import ArgumentParser
import Foundation
import ZipKit
import Sandbox

/// Pure-Swift port of Info-ZIP's `unzip(1)`. Covers the most-used
/// flags from `unzip -h`. Same exit-code conventions: 0 = success,
/// non-zero on errors.
public struct UnzipCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unzip",
        abstract: "Extract files from a PKZIP archive."
    )

    @Argument(help: "Archive (.zip). Use '-' to read from stdin.")
    public var archive: String

    @Argument(parsing: .remaining,
              help: "Glob patterns to include (positional). Empty = all files.")
    public var patterns: [String] = []

    @Option(name: [.customShort("x")],
            parsing: .singleValue,
            help: "Exclude entries matching PATTERN. Repeatable.")
    public var excludePatterns: [String] = []

    @Option(name: [.customShort("d")],
            help: "Destination directory.")
    public var destination: String = "."

    @Flag(name: [.customShort("l")],
          help: "List files (short format) without extracting.")
    public var list: Bool = false

    @Flag(name: [.customShort("v")],
          help: "List files verbosely; with -l prints sizes / methods / CRC.")
    public var verbose: Bool = false

    @Flag(name: [.customShort("t")],
          help: "Test archive integrity (CRC each entry); don't extract.")
    public var test: Bool = false

    @Flag(name: [.customShort("p")],
          help: "Pipe matching files to stdout, no headers, no progress.")
    public var pipe: Bool = false

    @Flag(name: [.customShort("o")],
          help: "Overwrite existing files without prompting.")
    public var overwrite: Bool = false

    @Flag(name: [.customShort("n")],
          help: "Never overwrite existing files.")
    public var neverOverwrite: Bool = false

    @Flag(name: [.customShort("j")],
          help: "Junk paths — flatten the archive when extracting.")
    public var junkPaths: Bool = false

    @Flag(name: [.customShort("q")],
          help: "Quiet mode (suppress per-file progress).")
    public var quiet: Bool = false

    @Flag(name: [.customShort("C")],
          help: "Match include / exclude patterns case-insensitively.")
    public var caseInsensitive: Bool = false

    public init() {}

    public func run() async throws {
        let includes = patterns
        let excludes = excludePatterns

        // `unzip -` reads the archive bytes from stdin and routes
        // through ZipKit's Data-based entry points.
        if archive == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            if list {
                try await doList(source: .data(data), includes: includes, excludes: excludes)
                return
            }
            if test {
                try await doTest(source: .data(data))
                return
            }
            if pipe {
                try await doPipe(source: .data(data), includes: includes, excludes: excludes)
                return
            }
            try await doExtract(source: .data(data), includes: includes, excludes: excludes)
            return
        }

        let archiveURL = Sandbox.resolve(archive)
        if list {
            try await doList(source: .url(archiveURL), includes: includes, excludes: excludes)
            return
        }
        if test {
            try await doTest(source: .url(archiveURL))
            return
        }
        if pipe {
            try await doPipe(source: .url(archiveURL), includes: includes, excludes: excludes)
            return
        }
        try await doExtract(source: .url(archiveURL), includes: includes, excludes: excludes)
    }

    /// Whether the archive came from a path on disk or a stdin slurp.
    /// Used so each operation can pick the right ZipKit overload.
    private enum Source {
        case url(URL)
        case data(Data)
    }

    // MARK: Modes

    private func doList(
        source: Source, includes: [String], excludes: [String]
    ) async throws {
        let entries: [Entry]
        switch source {
        case .url(let url):  entries = try await Archive.list(at: url)
        case .data(let d):   entries = try await Archive.list(data: d)
        }
        let filtered = entries.filter { entry in
            include(path: entry.path, includes: includes, excludes: excludes)
        }
        if verbose {
            Stdio.print(" Length   Method     Size  CRC-32   Date     Name")
            Stdio.print(" ------   ------     ----  ------   ----     ----")
        } else {
            Stdio.print("  Length      Date    Time    Name")
            Stdio.print("---------  ---------- -----   ----")
        }
        var totalUncompressed: Int64 = 0
        for e in filtered {
            totalUncompressed += e.uncompressedSize
            let date = e.modificationDate.map(Self.dateFormatter.string(from:)) ?? "-"
            if verbose {
                let method = e.compressionMethod == .store ? "Stored " : "Defl:N "
                let crc = String(format: "%08X", e.crc32)
                Stdio.print(String(format: "%7lld  %@  %7lld  %@  %@  %@",
                             e.uncompressedSize, method,
                             e.compressedSize, crc, date, e.path))
            } else {
                Stdio.print(String(format: "%9lld  %@   %@",
                             e.uncompressedSize, date, e.path))
            }
        }
        Stdio.print("---------                     -------")
        Stdio.print(String(format: "%9lld                     %lld file%@",
                     totalUncompressed,
                     Int64(filtered.count),
                     filtered.count == 1 ? "" : "s"))
    }

    private func doTest(source: Source) async throws {
        let entries: [Entry]
        let label: String
        switch source {
        case .url(let url):
            entries = try await Archive.test(at: url)
            label = url.lastPathComponent
        case .data(let d):
            entries = try await Archive.test(data: d)
            label = "<stdin>"
        }
        if !quiet {
            for e in entries where e.kind == .file {
                Stdio.print("    testing: \(e.path)\t OK")
            }
            Stdio.print("No errors detected in compressed data of \(label).")
        }
    }

    private func doPipe(
        source: Source, includes: [String], excludes: [String]
    ) async throws {
        switch source {
        case .url(let url):
            let entries = try await Archive.list(at: url)
            for e in entries where e.kind == .file
                && include(path: e.path, includes: includes, excludes: excludes)
            {
                try Task.checkCancellation()
                let data = try await Archive.read(entry: e.path, from: url)
                Stdio.stdout.write(data)
            }
        case .data(let d):
            let entries = try await Archive.list(data: d)
            for e in entries where e.kind == .file
                && include(path: e.path, includes: includes, excludes: excludes)
            {
                try Task.checkCancellation()
                let bytes = try await Archive.read(entry: e.path, data: d)
                Stdio.stdout.write(bytes)
            }
        }
    }

    private func doExtract(
        source: Source, includes: [String], excludes: [String]
    ) async throws {
        if overwrite && neverOverwrite {
            throw ValidationError("Specify -o (overwrite) OR -n (never), not both.")
        }
        let mode: ExtractOptions.OverwriteMode =
            neverOverwrite ? .no : (overwrite ? .yes : .yes)
        // Info-ZIP's interactive prompt isn't covered here; we default
        // to 'yes' (overwrite) when neither flag is set, matching the
        // `-o` behavior. Pass `-n` to refuse overwrites.

        let options = ExtractOptions(
            destination: Sandbox.resolve(destination),
            overwrite: mode,
            junkPaths: junkPaths,
            includes: includes,
            excludes: excludes,
            caseInsensitive: caseInsensitive,
            quiet: quiet)
        let written: [Entry]
        let label: String
        switch source {
        case .url(let url):
            written = try await Archive.extract(from: url, options: options)
            label = url.lastPathComponent
        case .data(let d):
            written = try await Archive.extract(from: d, options: options)
            label = "<stdin>"
        }
        if !quiet {
            Stdio.print("Archive:  \(label)")
            for e in written {
                let action = e.kind == .directory ? "  creating: " :
                             (e.compressionMethod == .store ? " extracting: " :
                                                              "  inflating: ")
                Stdio.print("\(action)\(e.path)")
            }
        }
    }

    // MARK: Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd-yyyy HH:mm"
        return f
    }()

    private func include(
        path: String, includes: [String], excludes: [String]
    ) -> Bool {
        if !includes.isEmpty,
           !GlobMatcher.matchesAny(patterns: includes,
                                   name: path,
                                   caseInsensitive: caseInsensitive)
        {
            return false
        }
        if GlobMatcher.matchesAny(patterns: excludes,
                                  name: path,
                                  caseInsensitive: caseInsensitive)
        {
            return false
        }
        return true
    }
}
