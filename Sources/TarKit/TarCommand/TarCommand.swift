import ArgumentParser
import Foundation
import TarKit
import Sandbox

/// Pure-Swift port of `tar(1)`. Covers the common create / extract /
/// list flows plus the `-z` gzip filter — enough for the typical
/// `tar -czf out.tgz dir/` and `tar -xzf in.tgz [-C dir]` usage seen
/// in CI scripts and developer workflows.
public struct TarCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tar",
        abstract: "Manipulate tar archives.",
        discussion: """
        Common usage:
          tar -czf out.tar.gz dir/         create gzipped archive
          tar -xzf in.tar.gz [-C dir]      extract gzipped archive
          tar -tzvf in.tar.gz              list gzipped archive verbosely

        Compression on read is auto-detected — `-z` is only needed for
        create. Supported read filters: gzip plus any libarchive picks
        up from the stream's magic bytes (when our build links them).
        """
    )

    @Flag(name: [.customShort("c")],
          help: "Create a new archive.")
    public var create: Bool = false

    @Flag(name: [.customShort("x")],
          help: "Extract files from archive.")
    public var extract: Bool = false

    @Flag(name: [.customShort("t")],
          help: "List archive contents.")
    public var list: Bool = false

    @Option(name: [.customShort("f")],
            help: "Archive file path.")
    public var file: String?

    @Flag(name: [.customShort("z")],
          help: "Filter archive through gzip (write side only — reads auto-detect).")
    public var gzip: Bool = false

    @Flag(name: [.customShort("j")],
          help: "Filter archive through bzip2 (write side only — macOS/Linux/Windows).")
    public var bzip2: Bool = false

    @Flag(name: [.customShort("J")],
          help: "Filter archive through xz (write side only — macOS/Linux/Windows).")
    public var xz: Bool = false

    @Flag(name: .customLong("zstd"),
          help: "Filter archive through zstd (write side only — macOS/Linux/Windows).")
    public var zstd: Bool = false

    @Flag(name: [.customShort("v")],
          help: "Verbose progress.")
    public var verbose: Bool = false

    @Option(name: [.customShort("C")],
            help: "Change to directory before extraction.")
    public var changeDir: String?

    @Option(name: .customLong("strip-components"),
            help: "Strip N leading path components on extract.")
    public var stripComponents: Int = 0

    @Argument(parsing: .remaining,
              help: "Files / directories to add (with -c) or selectors (with -x, -t).")
    public var args: [String] = []

    public init() {}

    public func run() async throws {
        let modes = [create, extract, list].filter { $0 }
        guard modes.count == 1 else {
            throw ValidationError(
                "Exactly one mode flag is required: -c (create), -x (extract), or -t (list).")
        }
        guard let file else {
            throw ValidationError(
                "Missing archive file: use -f <archive>.")
        }

        if create {
            try await runCreate(file: file)
        } else if extract {
            try await runExtract(file: file)
        } else {
            try await runList(file: file)
        }
    }

    private func runCreate(file: String) async throws {
        guard !args.isEmpty else {
            throw ValidationError(
                "Provide at least one file or directory to add.")
        }
        let filterCount = [gzip, bzip2, xz, zstd].filter { $0 }.count
        guard filterCount <= 1 else {
            throw ValidationError(
                "At most one compression filter (-z / -j / -J / --zstd).")
        }
        let compression: Compression
        if gzip { compression = .gzip }
        else if bzip2 { compression = .bzip2 }
        else if xz { compression = .xz }
        else if zstd { compression = .zstd }
        else { compression = .none }
        let url = Sandbox.resolve(file)
        let inputs = args.map { Sandbox.resolve($0) }
        let opts = CreateOptions(
            compression: compression,
            recursive: true,
            followSymlinks: false)
        let written = try await TarKit.Archive.create(
            at: url, paths: inputs, options: opts)
        if verbose {
            for e in written {
                Stdio.stderr.write(
                    Data("a \(e.path)\n".utf8))
            }
        }
    }

    private func runExtract(file: String) async throws {
        let archiveURL = Sandbox.resolve(file)
        let dest: URL
        if let dir = changeDir {
            dest = Sandbox.resolve(dir)
        } else {
            dest = Sandbox.currentDirectory
        }
        let opts = ExtractOptions(
            destination: dest,
            overwrite: true,
            stripComponents: stripComponents)
        let extracted = try await TarKit.Archive.extract(
            from: archiveURL, options: opts)
        if verbose {
            for e in extracted {
                Stdio.stderr.write(
                    Data("x \(e.path)\n".utf8))
            }
        }
    }

    private func runList(file: String) async throws {
        let url = Sandbox.resolve(file)
        try await Sandbox.authorize(url)
        let entries = try await TarKit.Archive.list(at: url)
        for e in entries {
            if verbose {
                let kindChar: String
                switch e.kind {
                case .file: kindChar = "-"
                case .directory: kindChar = "d"
                case .symlink: kindChar = "l"
                }
                let modeStr = String(format: "%04o", e.mode)
                let sizeStr = String(format: "%10lld", e.size)
                let dateStr = e.modificationDate.map {
                    Self.dateFormatter.string(from: $0)
                } ?? "-"
                Stdio.print("\(kindChar)\(modeStr) \(sizeStr) \(dateStr) \(e.path)")
            } else {
                Stdio.print(e.path)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
