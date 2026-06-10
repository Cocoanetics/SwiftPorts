import Foundation
import CGitKit

/// One index entry as `git ls-files -s` would render it: the
/// stage number (0 normally, 1/2/3 during a merge), the mode the
/// file is checked in with, the blob OID, and the relative path.
public struct IndexedEntry: Sendable, Equatable {
    public let path: String
    public let mode: UInt32
    public let oid: String
    public let stage: Int

    public init(path: String, mode: UInt32, oid: String, stage: Int) {
        self.path = path
        self.mode = mode
        self.oid = oid
        self.stage = stage
    }
}

extension Repository {

    /// Resolve `spec` (a ref, sha, abbrev, `<ref>~N`, etc.) to a full
    /// 40-char SHA. Throws when the spec can't be resolved.
    public func resolveOID(_ spec: String) throws -> String {
        var obj: OpaquePointer?
        try check(git_revparse_single(&obj, repo, spec))
        defer { git_object_free(obj) }
        var oid = git_object_id(obj)?.pointee ?? git_oid()
        return formatOID(&oid)
    }

    /// Path to the repo's `.git` directory (or the bare-repo root for
    /// bare repos). Equivalent of `git rev-parse --git-dir`.
    public func gitDir() throws -> String? {
        git_repository_path(repo).map { String(cString: $0) }
    }

    /// Working-tree root, the value `git rev-parse --show-toplevel`
    /// prints. Nil for bare repositories.
    public func toplevel() throws -> String? {
        git_repository_workdir(repo).map { String(cString: $0) }
    }

    /// Tracked file paths (everything currently in the index).
    /// Equivalent of `git ls-files` with no flags.
    public func indexedPaths() throws -> [String] {
        try indexedEntries().map(\.path)
    }

    /// Full index entries — mode, OID, stage, path. Backs
    /// `git ls-files -s` / `--stage`. Returns entries in the order
    /// libgit2 walks them (sorted by path with merge stages
    /// interleaved per real git output).
    public func indexedEntries() throws -> [IndexedEntry] {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        let count = Int(git_index_entrycount(index))
        var entries: [IndexedEntry] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            guard let raw = git_index_get_byindex(index, i)?.pointee,
                  let p = raw.path
            else { continue }
            var oid = raw.id
            let oidString = String(unsafeUninitializedCapacity: 40) { buf in
                git_oid_fmt(buf.baseAddress, &oid)
                return 40
            }
            // The high 4 bits of `flags` encode the merge stage
            // (`GIT_INDEX_ENTRY_STAGE`). Real ls-files prints
            // that number as the third column.
            let stage = Int((raw.flags >> 12) & 0x3)
            entries.append(IndexedEntry(
                path: String(cString: p),
                mode: raw.mode,
                oid: oidString,
                stage: stage))
        }
        return entries
    }

    /// True when the repository has a working tree — i.e. it is not
    /// bare. Backs `git rev-parse --is-inside-work-tree`.
    public func isInsideWorkTree() throws -> Bool {
        git_repository_workdir(repo) != nil
    }
}
