import Foundation
import ShellKit
import libgit2

// Selective imports — the libarchive wrapper module is named `Archive`
// and its own `enum Archive` / `ArchiveFormat` / `ArchiveFilter` would
// collide with the public SwiftGit names below if we used a module-
// level `import Archive`.
import struct Archive.ArchiveEntry
import class Archive.ArchiveWriter
import enum Archive.ArchiveFormat
import enum Archive.ArchiveFilter
import enum Archive.FileType

/// Output formats `archiveTree` can produce. tar variants are
/// libarchive's pax-restricted tar with the named filter; zip is
/// libarchive's PKZIP with default deflate. The bz2 / xz / zstd
/// arms only work where libarchive was compiled with the matching
/// trait — macOS / Linux / Windows. iOS / Android writes throw
/// libarchive's "filter not enabled" error.
public enum GitArchiveFormat: Sendable, Equatable {
    case tar
    case tarGzip
    case tarBzip2
    case tarXz
    case tarZstd
    case zip
}

extension GitClient {

    /// Walk `treeish`'s tree and emit each blob as an archive entry.
    /// No `Process` spawn, no shell-out — entries are streamed straight
    /// into the libarchive writer the format selects, exactly the
    /// invariant we need for sandboxed iOS / tvOS / watchOS / Android.
    ///
    /// - Parameter prefix: prepended to every entry path. Trailing
    ///   slash is added if missing. Matches `git archive --prefix=`.
    public func archiveTree(
        treeish: String = "HEAD",
        format: GitArchiveFormat,
        to output: URL,
        prefix: String? = nil
    ) async throws {
        try await Shell.authorize(output)
        let walk = try await collectBlobEntries(
            treeish: treeish, prefix: normalizedPrefix(prefix))
        try writeArchive(
            entries: walk.entries,
            mtime: walk.mtime,
            to: output, format: format)
    }

    fileprivate struct BlobEntry {
        let path: String
        let mode: UInt16
        let isExecutable: Bool
        let isSymlink: Bool
        let bytes: Data
    }

    fileprivate struct WalkResult {
        let entries: [BlobEntry]
        /// Time stamped on every output archive entry. Pulled from the
        /// commit (or tag→commit) the treeish resolves to so the same
        /// SHA produces a byte-identical archive across runs — matches
        /// upstream `git archive`'s reproducibility guarantee. Falls
        /// back to `Date()` when the treeish is a raw tree (no commit
        /// context, no canonical timestamp).
        let mtime: Date
    }

    private func collectBlobEntries(
        treeish: String, prefix: String
    ) async throws -> WalkResult {
        try await withRepository { repo in
            var obj: OpaquePointer?
            try check(treeish.withCString { name in
                git_revparse_single(&obj, repo, name)
            })
            defer { git_object_free(obj) }

            var tree: OpaquePointer?
            try check(git_object_peel(&tree, obj, GIT_OBJECT_TREE))
            defer { git_object_free(tree) }

            // Try to peel to a commit for the canonical timestamp.
            // Raw-tree SHAs (rare in `git archive` use) have no commit
            // context — fall back to current wall-clock.
            var mtime = Date()
            var commit: OpaquePointer?
            if git_object_peel(&commit, obj, GIT_OBJECT_COMMIT) == 0 {
                defer { git_object_free(commit) }
                let unix = git_commit_time(commit)
                mtime = Date(timeIntervalSince1970: TimeInterval(unix))
            }

            var collected: [BlobEntry] = []
            try walkBlobs(
                repo: repo, tree: tree, prefix: prefix, into: &collected)
            return WalkResult(entries: collected, mtime: mtime)
        }
    }

    /// Recursive tree walk emitting one BlobEntry per blob. Matches
    /// `git ls-tree -r` order (alphabetical within each subtree).
    private func walkBlobs(
        repo: OpaquePointer?,
        tree: OpaquePointer?,
        prefix: String,
        into collected: inout [BlobEntry]
    ) throws {
        let count = git_tree_entrycount(tree)
        for i in 0..<count {
            try Task.checkCancellation()
            guard let entry = git_tree_entry_byindex(tree, i) else { continue }
            let name = String(cString: git_tree_entry_name(entry))
            let kind = git_tree_entry_type(entry)
            let mode = git_tree_entry_filemode(entry)
            switch kind {
            case GIT_OBJECT_TREE:
                var sub: OpaquePointer?
                if git_tree_lookup(&sub, repo, git_tree_entry_id(entry)) == 0 {
                    defer { git_object_free(sub) }
                    try walkBlobs(
                        repo: repo, tree: sub,
                        prefix: prefix + name + "/",
                        into: &collected)
                }
            case GIT_OBJECT_BLOB:
                var blob: OpaquePointer?
                try check(git_blob_lookup(
                    &blob, repo, git_tree_entry_id(entry)))
                defer { git_object_free(blob) }
                let size = Int(git_blob_rawsize(blob))
                let bytes: Data
                if size > 0, let raw = git_blob_rawcontent(blob) {
                    bytes = Data(bytes: raw, count: size)
                } else {
                    bytes = Data()
                }
                let modeRaw = mode.rawValue
                // libgit2 file modes follow POSIX mode bits:
                //   100644 = regular, 100755 = executable, 120000 = symlink.
                let isExec = (modeRaw == 0o100755)
                let isLink = (modeRaw == 0o120000)
                let unixMode: UInt16 = isLink ? 0o755
                    : (isExec ? 0o755 : 0o644)
                collected.append(BlobEntry(
                    path: prefix + name,
                    mode: unixMode,
                    isExecutable: isExec,
                    isSymlink: isLink,
                    bytes: bytes))
            case GIT_OBJECT_COMMIT:
                // Submodule entries (gitlinks) — `git archive` skips
                // them by default; do the same.
                continue
            default:
                continue
            }
        }
    }

    private func normalizedPrefix(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        if raw.hasSuffix("/") { return raw }
        return raw + "/"
    }

    private func writeArchive(
        entries: [BlobEntry],
        mtime: Date,
        to output: URL,
        format: GitArchiveFormat
    ) throws {
        let archiveFormat: ArchiveFormat
        let filters: [ArchiveFilter]
        switch format {
        case .tar:       archiveFormat = .tar; filters = [.none]
        case .tarGzip:   archiveFormat = .tar; filters = [.gzip]
        case .tarBzip2:  archiveFormat = .tar; filters = [.bzip2]
        case .tarXz:     archiveFormat = .tar; filters = [.xz]
        case .tarZstd:   archiveFormat = .tar; filters = [.zstd]
        case .zip:       archiveFormat = .zip; filters = [.none]
        }

        let writer = try ArchiveWriter(
            path: output.path, format: archiveFormat, filters: filters)
        var closed = false
        defer { if !closed { try? writer.close() } }

        for entry in entries {
            let archiveEntry = ArchiveEntry(
                pathname: entry.path,
                size: Int64(entry.isSymlink ? 0 : entry.bytes.count),
                fileType: entry.isSymlink ? .symbolicLink : .regular,
                permissions: entry.mode,
                modificationDate: mtime,
                symlinkTarget: entry.isSymlink
                    ? String(data: entry.bytes, encoding: .utf8)
                    : nil)
            try writer.writeEntry(
                archiveEntry,
                data: entry.isSymlink ? nil : entry.bytes)
        }
        try writer.close()
        closed = true
    }
}
