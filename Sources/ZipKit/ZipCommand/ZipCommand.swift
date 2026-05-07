import ArgumentParser
import Foundation
import ZipKit
import Sandbox

/// Pure-Swift port of Info-ZIP's `zip(1)`. Covers the most-used flags
/// from `zip -h`. Adds (or replaces) entries in a PKZIP archive.
public struct ZipCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "zip",
        abstract: "Create or update a PKZIP archive."
    )

    @Argument(help: "Output archive (.zip). Replaced if it already exists.")
    public var archive: String

    @Argument(parsing: .remaining,
              help: "Files / directories to add to the archive.")
    public var inputs: [String] = []

    @Option(name: [.customShort("x")],
            parsing: .singleValue,
            help: "Exclude entries matching PATTERN. Repeatable.")
    public var excludePatterns: [String] = []

    @Option(name: [.customShort("i")],
            parsing: .singleValue,
            help: "Only include entries matching PATTERN. Repeatable.")
    public var includePatterns: [String] = []

    @Flag(name: [.customShort("r")],
          help: "Recurse into directories.")
    public var recursive: Bool = false

    @Flag(name: [.customShort("j")],
          help: "Junk paths — store only the basename of each entry.")
    public var junkPaths: Bool = false

    @Flag(name: [.customShort("0")],
          help: "Store only (no compression).")
    public var store: Bool = false

    @Flag(name: [.customShort("1")], help: "Compress fast.")
    public var fast: Bool = false
    @Flag(name: [.customShort("9")], help: "Compress better.")
    public var best: Bool = false

    @Flag(name: [.customShort("q")], help: "Quiet operation.")
    public var quiet: Bool = false

    @Flag(name: [.customShort("v")], help: "Verbose progress.")
    public var verbose: Bool = false

    @Flag(name: [.customShort("y")],
          help: "Store symlinks as the link instead of following them.")
    public var storeSymlinks: Bool = false

    @Flag(name: [.customShort("D")],
          help: "Don't add directory entries.")
    public var noDirEntries: Bool = false

    @Flag(name: [.customShort("X")],
          help: "Don't preserve file attributes (timestamps, perms).")
    public var noAttributes: Bool = false

    public init() {}

    public func run() async throws {
        guard !inputs.isEmpty else {
            throw ValidationError("Provide at least one file or directory to add.")
        }

        let inputURLs = inputs.map { Sandbox.resolve($0) }
        let options = CreateOptions(
            recursive: recursive,
            junkPaths: junkPaths,
            compressionMethod: store ? .store : .deflate,
            quiet: quiet,
            includes: includePatterns,
            excludes: excludePatterns,
            followSymlinks: !storeSymlinks,
            includeDirectories: !noDirEntries)

        let outputURL = Sandbox.resolve(archive)
        let written = try await ZipKit.Archive.create(
            at: outputURL, paths: inputURLs, options: options)

        if !quiet {
            for e in written {
                let action: String
                switch e.kind {
                case .directory: action = "  adding: "
                case .symlink:   action = " linking: "
                case .file:
                    action = e.compressionMethod == .store ?
                        " storing: " : "deflating: "
                }
                Stdio.print("\(action)\(e.path)")
            }
        }
    }
}
