import Foundation
import ShellKit
// Selective imports — the libarchive wrapper module is named `Archive`
// and exposes its own `enum Archive` (just for version metadata) which
// would collide with our public `enum Archive` below.
import struct Archive.ArchiveEntry
import class Archive.ArchiveReader
import class Archive.ArchiveWriter
import enum Archive.ArchiveFormat
import enum Archive.ArchiveFilter
import enum Archive.FileType

/// High-level facade over libarchive (via marcprux/swift-archive) for
/// the operations zip(1) and unzip(1) need. Cross-platform (Apple +
/// Linux + Windows + Android), no `Process` calls.
public enum Archive {

    // MARK: List

    public static func list(at url: URL) async throws -> [Entry] {
        try await Shell.authorize(url)
        let reader = try newReader(at: url)
        return try collectEntries(reader: reader, readData: false).map(\.entry)
    }

    public static func list(data: Data) async throws -> [Entry] {
        let reader = try newReader(data: data)
        return try collectEntries(reader: reader, readData: false).map(\.entry)
    }

    // MARK: Test integrity

    /// Walks every entry, reading its bytes — libarchive validates
    /// per-format checksums (CRC32 for zip) during data reads, so a
    /// successful walk implies integrity. Cooperatively cancellable.
    @discardableResult
    public static func test(at url: URL) async throws -> [Entry] {
        try await Shell.authorize(url)
        let reader = try newReader(at: url)
        return try collectEntries(reader: reader, readData: true).map(\.entry)
    }

    @discardableResult
    public static func test(data: Data) async throws -> [Entry] {
        let reader = try newReader(data: data)
        return try collectEntries(reader: reader, readData: true).map(\.entry)
    }

    // MARK: Read a single entry

    /// Returns the decompressed bytes of `entryPath`. Used by `unzip -p`.
    public static func read(entry entryPath: String, from url: URL) async throws -> Data {
        try await Shell.authorize(url)
        let reader = try newReader(at: url)
        return try readSingleEntry(reader: reader, path: entryPath)
    }

    public static func read(entry entryPath: String, data: Data) async throws -> Data {
        let reader = try newReader(data: data)
        return try readSingleEntry(reader: reader, path: entryPath)
    }

    // MARK: Stream entries to a FileHandle

    /// Writes each matching entry's bytes to `handle`, prefixed with a
    /// `=== <path> ===` header. Used by `unzip -p` (no header) and by
    /// SwiftGH's `gh run view --log` (header per file). Set
    /// `printHeaders: false` to omit the prefix. Cooperatively
    /// cancellable per entry.
    ///
    /// **Sandbox note.** This function does NOT call
    /// `Sandbox.authorize` — the caller already opened the
    /// `FileHandle` from a URL, and gating happens at that open
    /// site. Callers must ensure the URL backing `handle` was
    /// authorized before this call. The archive bytes (`data`) are
    /// in-memory and don't go through the URL gate.
    public static func streamEntries(
        from data: Data,
        to handle: OutputSink,
        matching options: ExtractOptions = .init(destination: URL(fileURLWithPath: "")),
        printHeaders: Bool = true
    ) async throws {
        let reader = try newReader(data: data)
        var collected: [(path: String, data: Data)] = []
        try reader.forEachEntry { entry, reader in
            try Task.checkCancellation()
            guard entry.fileType == .regular else { return }
            guard shouldInclude(entryPath: entry.pathname,
                                includes: options.includes,
                                excludes: options.excludes,
                                caseInsensitive: options.caseInsensitive)
            else { return }
            let bytes = try reader.readData()
            collected.append((entry.pathname, bytes))
        }
        for (path, bytes) in collected.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            if printHeaders {
                handle.write(Data("\n=== \(path) ===\n".utf8))
            }
            handle.write(bytes)
        }
    }

    // MARK: Extract

    @discardableResult
    public static func extract(
        from url: URL, options: ExtractOptions
    ) async throws -> [Entry] {
        try await Shell.authorize(url)
        try await Shell.authorize(options.destination)
        let reader = try newReader(at: url)
        return try extract(reader: reader, options: options)
    }

    @discardableResult
    public static func extract(
        from data: Data, options: ExtractOptions
    ) async throws -> [Entry] {
        try await Shell.authorize(options.destination)
        let reader = try newReader(data: data)
        return try extract(reader: reader, options: options)
    }

    private static func extract(
        reader: ArchiveReader, options: ExtractOptions
    ) throws -> [Entry] {
        try FileManager.default.createDirectory(
            at: options.destination, withIntermediateDirectories: true)

        var written: [Entry] = []
        try reader.forEachEntry { native, reader in
            try Task.checkCancellation()
            // `-j` (junk paths) means flat extraction — skip directory
            // entries entirely; for files take only the basename.
            if options.junkPaths && native.fileType == .directory {
                return
            }
            let path = options.junkPaths
                ? (native.pathname as NSString).lastPathComponent
                : native.pathname
            guard !path.isEmpty else { return }
            guard shouldInclude(entryPath: native.pathname,
                                includes: options.includes,
                                excludes: options.excludes,
                                caseInsensitive: options.caseInsensitive)
            else { return }
            // sanitize returns:
            //   nil  → hostile path (refuse archive)
            //   ""   → legit no-op — skip
            //   else → safe normalized relative path / basename
            guard let safe = options.junkPaths
                ? sanitizeBasename(path)
                : sanitizeRelativePath(path)
            else {
                throw ZipKitError.unsafeEntryPath(native.pathname)
            }
            if safe.isEmpty { return }

            let target = options.destination.appendingPathComponent(safe)
            let exists = FileManager.default.fileExists(atPath: target.path)
            if exists {
                switch options.overwrite {
                case .yes: try? FileManager.default.removeItem(at: target)
                case .no: return
                case .error: throw ZipKitError.destinationExists(target)
                }
            }

            do {
                switch native.fileType {
                case .directory:
                    try FileManager.default.createDirectory(
                        at: target, withIntermediateDirectories: true)
                case .symbolicLink:
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    if let link = native.symlinkTarget {
                        // Preserve the raw symlink target string —
                        // `URL(fileURLWithPath:)` would resolve a
                        // relative target against cwd and lose its
                        // relativity entirely.
                        try FileManager.default.createSymbolicLink(
                            atPath: target.path,
                            withDestinationPath: link)
                    }
                default: // .regular and other "file-like" types
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    let bytes = try reader.readData()
                    try bytes.write(to: target)
                }
            } catch let error as ZipKitError { throw error }
            catch {
                throw ZipKitError.writeFailed(target,
                    underlying: error.localizedDescription)
            }
            written.append(map(entry: native, hadDataRead: false))
        }
        return written
    }

    // MARK: Create

    /// Build a new archive at `zipURL` containing every matching file
    /// in `paths`. Directories are walked when `recursive` is set.
    @discardableResult
    public static func create(
        at zipURL: URL,
        paths: [URL],
        options: CreateOptions = .init()
    ) async throws -> [Entry] {
        try await Shell.authorize(zipURL)
        for input in paths {
            try await Shell.authorize(input)
        }
        // Remove an existing archive — Info-ZIP appends to existing
        // archives by default but our minimal port replaces them.
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        let writer: ArchiveWriter
        do {
            writer = try ArchiveWriter(path: zipURL.path, format: .zip)
        } catch {
            throw ZipKitError.archiveOpenFailed(Shell.displayPath(for: zipURL))
        }

        var written: [Entry] = []
        let toAdd = try resolveInputs(paths: paths, options: options)
        for resolved in toAdd {
            try Task.checkCancellation()
            let baseAttrs = (try? FileManager.default.attributesOfItem(
                atPath: resolved.source.path)) ?? [:]
            let isDir = (baseAttrs[.type] as? FileAttributeType) == .typeDirectory
            let isSymlink = (baseAttrs[.type] as? FileAttributeType) == .typeSymbolicLink
            let modDate = (baseAttrs[.modificationDate] as? Date) ?? Date()
            let perms = (baseAttrs[.posixPermissions] as? NSNumber)?.uint16Value

            if isDir {
                if options.includeDirectories {
                    let dirPath = resolved.entryPath.hasSuffix("/")
                        ? resolved.entryPath
                        : resolved.entryPath + "/"
                    let entry = ArchiveEntry(
                        pathname: dirPath,
                        size: 0,
                        fileType: .directory,
                        permissions: perms ?? 0o755,
                        modificationDate: modDate)
                    try writer.writeEntry(entry)
                    written.append(syntheticDirEntry(path: dirPath))
                }
            } else if isSymlink && !options.followSymlinks {
                let dest = (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: resolved.source.path)) ?? ""
                let entry = ArchiveEntry(
                    pathname: resolved.entryPath,
                    size: 0,
                    fileType: .symbolicLink,
                    permissions: perms ?? 0o755,
                    modificationDate: modDate,
                    symlinkTarget: dest)
                try writer.writeEntry(entry)
                let bytes = Data(dest.utf8)
                written.append(Entry(
                    path: resolved.entryPath, kind: .symlink,
                    uncompressedSize: Int64(bytes.count),
                    compressedSize: Int64(bytes.count),
                    compressionMethod: .store,
                    crc32: 0, modificationDate: modDate))
            } else {
                let bytes = try Data(contentsOf: resolved.source)
                let entry = ArchiveEntry(
                    pathname: resolved.entryPath,
                    size: Int64(bytes.count),
                    fileType: .regular,
                    permissions: perms ?? 0o644,
                    modificationDate: modDate)
                try writer.writeEntry(entry, data: bytes)
                written.append(Entry(
                    path: resolved.entryPath, kind: .file,
                    uncompressedSize: Int64(bytes.count),
                    compressedSize: Int64(bytes.count),
                    compressionMethod: options.compressionMethod,
                    crc32: 0, modificationDate: modDate))
            }
        }
        try writer.close()
        return written
    }

    // MARK: Mapping helpers

    private static func map(entry native: ArchiveEntry, hadDataRead: Bool) -> Entry {
        let kind: Entry.Kind
        switch native.fileType {
        case .directory: kind = .directory
        case .symbolicLink: kind = .symlink
        default: kind = .file
        }
        // libarchive doesn't surface the per-entry CRC or compressed
        // size for zip via the Swift wrapper; treat compressed == uncompressed
        // (effectively `.store`) and crc32 = 0. List/test consumers of
        // SwiftPorts only check path / kind / sizes, not these fields.
        let path: String
        if kind == .directory && !native.pathname.hasSuffix("/") {
            path = native.pathname + "/"
        } else {
            path = native.pathname
        }
        return Entry(
            path: path,
            kind: kind,
            uncompressedSize: native.size,
            compressedSize: native.size,
            compressionMethod: native.size == 0 ? .store : .deflate,
            crc32: 0,
            modificationDate: native.modificationDate)
    }

    private static func syntheticDirEntry(path: String) -> Entry {
        Entry(path: path, kind: .directory,
              uncompressedSize: 0, compressedSize: 0,
              compressionMethod: .store, crc32: 0, modificationDate: nil)
    }

    /// Walks every entry once. When `readData` is true, each entry's
    /// bytes are read (forces libarchive to validate per-format
    /// checksums); the data itself is discarded.
    private static func collectEntries(
        reader: ArchiveReader, readData: Bool
    ) throws -> [(entry: Entry, native: ArchiveEntry)] {
        var out: [(entry: Entry, native: ArchiveEntry)] = []
        try reader.forEachEntry { native, reader in
            try Task.checkCancellation()
            if readData && native.fileType == .regular {
                _ = try reader.readData()
            }
            out.append((map(entry: native, hadDataRead: readData), native))
        }
        return out
    }

    private static func readSingleEntry(
        reader: ArchiveReader, path entryPath: String
    ) throws -> Data {
        var found: Data?
        try reader.forEachEntry { native, reader in
            try Task.checkCancellation()
            guard found == nil else { return }
            if native.pathname == entryPath {
                found = try reader.readData()
            }
        }
        guard let bytes = found else {
            throw ZipKitError.entryNotFound(entryPath)
        }
        return bytes
    }

    // MARK: Input resolution (for create)

    private struct ResolvedInput {
        let source: URL
        let entryPath: String
    }

    private static func resolveInputs(
        paths: [URL], options: CreateOptions
    ) throws -> [ResolvedInput] {
        var resolved: [ResolvedInput] = []
        for input in paths {
            try walk(source: input, prefix: nil,
                     into: &resolved, options: options)
        }
        return resolved
    }

    private static func walk(
        source: URL, prefix: String?, into resolved: inout [ResolvedInput],
        options: CreateOptions
    ) throws {
        try Task.checkCancellation()
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let type = attrs[.type] as? FileAttributeType
        let topName = source.lastPathComponent

        let entryName: String
        if options.junkPaths {
            entryName = topName
        } else if let prefix {
            entryName = prefix.isEmpty ? topName : "\(prefix)/\(topName)"
        } else {
            entryName = topName
        }

        // Filter
        let nameForFilter = (entryName as NSString).lastPathComponent
        if !options.includes.isEmpty,
           !GlobMatcher.matchesAny(patterns: options.includes,
                                   name: nameForFilter) {
            return
        }
        if GlobMatcher.matchesAny(patterns: options.excludes,
                                  name: nameForFilter) {
            return
        }

        if type == .typeDirectory {
            if options.recursive {
                if options.includeDirectories {
                    resolved.append(.init(source: source, entryPath: entryName))
                }
                let children = try FileManager.default.contentsOfDirectory(
                    at: source, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
                for child in children.sorted(by: { $0.path < $1.path }) {
                    try walk(source: child, prefix: entryName,
                             into: &resolved, options: options)
                }
            }
        } else {
            resolved.append(.init(source: source, entryPath: entryName))
        }
    }

    // MARK: Helpers

    private static func newReader(at url: URL) throws -> ArchiveReader {
        do {
            return try ArchiveReader(path: url.path)
        } catch {
            throw ZipKitError.archiveOpenFailed(Shell.displayPath(for: url))
        }
    }

    private static func newReader(data: Data) throws -> ArchiveReader {
        do {
            return try ArchiveReader(data: data)
        } catch {
            throw ZipKitError.archiveOpenFailed(error.localizedDescription)
        }
    }

    /// Returns a normalized relative path under the destination root.
    /// `nil` means the entry is hostile (absolute, drive-letter, or
    /// `..`-traversing) and the caller should refuse the archive.
    /// An empty string means the entry resolved to a no-op (e.g. `.`
    /// or `./`) and the caller should skip it silently.
    private static func sanitizeRelativePath(_ raw: String) -> String? {
        if raw.isEmpty { return "" }
        if raw.hasPrefix("/") { return nil }
        if raw.hasPrefix("\\") { return nil }
        if raw.count >= 2 {
            let chars = Array(raw)
            if chars[1] == ":" && chars[0].isLetter { return nil }
        }
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        var out: [String] = []
        for piece in normalized.split(
            separator: "/", omittingEmptySubsequences: true)
        {
            let s = String(piece)
            if s == "." { continue }
            if s == ".." { return nil }
            out.append(s)
        }
        return out.joined(separator: "/")
    }

    /// Used for junk-paths extraction (`unzip -j`). The basename has
    /// already been collapsed via NSString.lastPathComponent. Empty /
    /// `.` resolves to skip; `..`, drive letters, and embedded
    /// separators are hostile.
    private static func sanitizeBasename(_ raw: String) -> String? {
        if raw.isEmpty { return "" }
        if raw == "." { return "" }
        if raw == ".." { return nil }
        if raw.hasPrefix("/") || raw.hasPrefix("\\") { return nil }
        if raw.contains("/") || raw.contains("\\") { return nil }
        return raw
    }

    private static func shouldInclude(
        entryPath: String,
        includes: [String], excludes: [String],
        caseInsensitive: Bool
    ) -> Bool {
        if !includes.isEmpty,
           !GlobMatcher.matchesAny(patterns: includes,
                                   name: entryPath,
                                   caseInsensitive: caseInsensitive)
        {
            return false
        }
        if GlobMatcher.matchesAny(patterns: excludes,
                                  name: entryPath,
                                  caseInsensitive: caseInsensitive)
        {
            return false
        }
        return true
    }
}
