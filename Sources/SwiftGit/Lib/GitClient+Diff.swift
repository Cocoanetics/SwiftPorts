import Foundation
import CGitKit
import GitKit
import ShellKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif os(Windows)
import WinSDK
#endif

// Sandbox-aware delegation onto the pure `Repository` diff operations
// (`GitKit/Repository+Diff.swift`). Each call authorizes the
// working directory and isolates libgit2's global config view via
// `withRepository`, then hands off. `diffIndex` reads libgit2 deltas
// through the repository handle: `Repository.diff`'s raw text
// abbreviates object ids and keeps a single path.
extension GitClient {

    /// Produce diff output as a single string — mirrors `git diff`'s
    /// stdout for the matching invocation.
    public func diff(
        _ target: DiffTarget,
        format: DiffFormat = .patch,
        paths: [String] = [],
        contextLines: UInt32? = nil
    ) async throws -> String {
        try await withRepository {
            try $0.diff(target, format: format, paths: paths, contextLines: contextLines)
        }
    }

    /// True iff `spec` resolves to an object via `git_revparse_single`.
    public func canResolveRef(_ spec: String) async throws -> Bool {
        try await withRepository { try $0.canResolveRef(spec) }
    }

    /// Compute the merge-base of two commit-ishes.
    public func mergeBase(_ a: String, _ b: String) async throws -> String {
        try await withRepository { try $0.mergeBase(a, b) }
    }

    /// `git diff-index` against `ref`, as typed records with full object ids.
    ///
    /// `cached` is `git diff-index --cached` (`git_diff_tree_to_index`).
    /// Otherwise the tree is compared to the working tree, using the index
    /// (`git_diff_tree_to_workdir_with_index`). Rename detection then runs
    /// at git's default 50% similarity, with copies left off. An unborn
    /// `HEAD` is the empty tree, so every indexed path is an addition.
    /// A side git has not hashed (a dirty work-tree file) is 40 zeros.
    /// A change between a regular file, a symlink, and a gitlink is one
    /// `T` record. Without `--cached`, an unmerged path is that work-tree
    /// comparison (`M`, `A`, `D`, or `T`); `U` is only the cached form.
    ///
    /// `refresh` applies only to an uncached diff. It is `git update-index
    /// --refresh` for files whose raw work-tree bytes match the stage-zero
    /// index blob: stat metadata is rewritten and a stat-only touch
    /// disappears. Content is never staged, and no clean or smudge filter
    /// runs. The default leaves the index untouched, so that stat-only
    /// touch is still reported, including when the new size matches.
    public func diffIndex(
        ref: String = "HEAD", cached: Bool, refresh: Bool = false
    ) async throws -> [DiffIndexEntry] {
        if refresh && !cached {
            try await authorizeIndexRefresh()
        }
        return try await withRepository { repository in
            try Self.performDiffIndex(
                ref: ref, cached: cached, refresh: refresh && !cached, repository: repository)
        }
    }

    /// Stage-zero work-tree paths and the index file, authorized before
    /// a refresh reads or rewrites them. A denial fails the call.
    private func authorizeIndexRefresh() async throws {
        let urls = try await withRepository { repository in
            try Self.refreshInputURLs(repository)
        }
        for url in urls {
            try await Shell.authorize(url)
        }
    }

    private static func refreshInputURLs(_ repository: Repository) throws -> [URL] {
        let repo = try repositoryHandle(repository)
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        return DiffIndexStat.inputURLs(repo, index: index)
    }

    private static func performDiffIndex(
        ref: String, cached: Bool, refresh: Bool, repository: Repository
    ) throws -> [DiffIndexEntry] {
        let repo = try repositoryHandle(repository)
        let tree = try diffIndexTree(ref, repo: repo)
        defer { git_tree_free(tree) }
        var opts = git_diff_options()
        try check(git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION)))
        // libgit2 splits a file/symlink/gitlink change into D + A
        // unless this is set. `git diff-index` prints one T.
        opts.flags |= UInt32(GIT_DIFF_INCLUDE_TYPECHANGE.rawValue)
        // Held across the diff: an in-memory size poke must not be
        // reloaded away, and a refresh is written only after that.
        let hold = cached ? nil : try DiffIndexStat.prepare(repo, refresh: refresh)
        defer { hold?.discard() }
        var diff: OpaquePointer?
        defer { git_diff_free(diff) }
        try fillDiffIndex(&diff, repo: repo, tree: tree, cached: cached, refresh: refresh, opts: &opts)
        try detectDiffIndexRenames(diff)
        // Detection can hash a candidate libgit2 still considers dirty.
        // When that correction changes the add/delete/type set, rebuild
        // once so detection runs on the corrected records.
        if refresh && !cached {
            let changed = try DiffIndexStat.correct(diff, repo: repo, tree: tree)
            if changed {
                try fillDiffIndex(
                    &diff, repo: repo, tree: tree, cached: cached, refresh: refresh, opts: &opts)
                try detectDiffIndexRenames(diff)
            }
        }
        // A size poke leaves a rename destination with a zero id. `git
        // diff-index -M` still prints the blob once the paths pair.
        DiffIndexStat.realizeRenames(diff, repo: repo)
        let entries = diffIndexEntries(diff)
        try hold?.persist(refresh: refresh)
        return entries
    }

    private static func fillDiffIndex(
        _ diff: inout OpaquePointer?,
        repo: OpaquePointer?,
        tree: OpaquePointer?,
        cached: Bool,
        refresh: Bool,
        opts: inout git_diff_options
    ) throws {
        git_diff_free(diff)
        diff = nil
        if cached {
            try check(git_diff_tree_to_index(&diff, repo, tree, nil, &opts))
            try normalizeCachedDiffIndex(diff, tree: tree)
            return
        }
        try check(git_diff_tree_to_workdir_with_index(&diff, repo, tree, &opts))
        try normalizeUncachedDiffIndex(diff, tree: tree)
        if refresh {
            _ = try DiffIndexStat.correct(diff, repo: repo, tree: tree)
        }
    }

    private static func repositoryHandle(_ repository: Repository) throws -> OpaquePointer {
        guard let repo = handle(of: repository) else {
            throw Libgit2Error(
                code: -1, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                message: "cannot reach GitKit's repository handle to diff the index")
        }
        return repo
    }

    /// The tree `spec` names, or nil when `HEAD` is unborn (the empty tree).
    private static func diffIndexTree(_ spec: String, repo: OpaquePointer?) throws -> OpaquePointer? {
        var object: OpaquePointer?
        let rc = git_revparse_single(&object, repo, spec)
        if rc != 0 {
            git_object_free(object)
            if spec == "HEAD", git_repository_head_unborn(repo) == 1 { return nil }
            try check(rc)
        }
        defer { git_object_free(object) }
        var tree: OpaquePointer?
        try check(git_object_peel(&tree, object, GIT_OBJECT_TREE))
        return tree
    }

    /// `git diff -M` at the default 50% threshold. Copies stay off:
    /// `GIT_DIFF_FIND_BY_CONFIG` would follow `diff.renames`, which can
    /// disable renames, and plain `git diff-index` does not turn them on.
    private static func detectDiffIndexRenames(_ diff: OpaquePointer?) throws {
        var find = git_diff_find_options()
        try check(git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)))
        find.flags = UInt32(GIT_DIFF_FIND_RENAMES.rawValue)
        find.rename_threshold = 50
        try check(git_diff_find_similar(diff, &find))
    }

    /// A file recorded in the tree `diffIndex` compares against.
    struct DiffIndexTreeFile {
        var mode: UInt16
        var id: git_oid
    }

    /// `git diff-index --cached` prints an unmerged path as `U` with an
    /// empty new side. libgit2 does that when the path is also in the
    /// tree; a path that is not (a modify/delete against this tree) keeps
    /// the conflict stage as the new file.
    private static func normalizeCachedDiffIndex(_ diff: OpaquePointer?, tree: OpaquePointer?) throws {
        let count = git_diff_num_deltas(diff)
        for index in 0..<count {
            guard let pointer = git_diff_get_delta(diff, index) else { continue }
            let delta = UnsafeMutablePointer(mutating: pointer)
            guard delta.pointee.status == GIT_DELTA_CONFLICTED else { continue }
            var record = delta.pointee
            guard let path = record.new_file.path ?? record.old_file.path else { continue }
            if let old = try treeFile(tree, path: path) {
                record.old_file = treeSide(record.old_file, file: old)
            } else {
                record.old_file = absentSide(record.old_file)
            }
            record.new_file = absentSide(record.new_file)
            record.nfiles = 1
            delta.pointee = record
        }
    }

    /// Make an uncached diff match `git diff-index` (no `--cached`).
    ///
    /// `git_diff_tree_to_workdir_with_index` merges a tree-to-index diff
    /// with an index-to-workdir diff. That merge keeps a conflict delta
    /// as the index recorded it, so the old side is empty, and it can
    /// leave a work-tree file labelled with the index's type-change
    /// status. Rename detection runs after this, so a deletion or
    /// addition created here is visible to `-M`.
    private static func normalizeUncachedDiffIndex(_ diff: OpaquePointer?, tree: OpaquePointer?) throws {
        let count = git_diff_num_deltas(diff)
        for index in 0..<count {
            guard let pointer = git_diff_get_delta(diff, index) else { continue }
            let delta = UnsafeMutablePointer(mutating: pointer)
            switch delta.pointee.status {
            case GIT_DELTA_CONFLICTED:
                try rewriteUnmerged(delta, tree: tree)
            case GIT_DELTA_TYPECHANGE:
                relabelMergedTypeChange(delta)
            default:
                break
            }
        }
    }

    /// An unmerged index entry compared with the work tree. The old side
    /// comes from `tree` (empty when the path is not in that tree). The
    /// new side is the work-tree file, with a zero id: `git diff-index`
    /// does not hash an unmerged work-tree file. A path in neither side
    /// is omitted.
    private static func rewriteUnmerged(
        _ delta: UnsafeMutablePointer<git_diff_delta>,
        tree: OpaquePointer?
    ) throws {
        var record = delta.pointee
        guard let path = record.new_file.path ?? record.old_file.path else {
            record.status = GIT_DELTA_UNMODIFIED
            delta.pointee = record
            return
        }
        let present = diffSideExists(record.new_file)
        let old = try treeFile(tree, path: path)
        if !present {
            if let old {
                record.status = GIT_DELTA_DELETED
                record.nfiles = 1
                record.old_file = treeSide(record.old_file, file: old)
                record.new_file = absentSide(record.new_file)
            } else {
                record.status = GIT_DELTA_UNMODIFIED
                record.old_file.mode = 0
                record.new_file.mode = 0
            }
            delta.pointee = record
            return
        }
        record.new_file.id = git_oid()
        record.new_file.flags &= ~UInt32(GIT_DIFF_FLAG_VALID_ID.rawValue)
        if let old {
            record.old_file = treeSide(record.old_file, file: old)
            record.nfiles = 2
            record.status = diffModeType(old.mode) == diffModeType(record.new_file.mode)
                ? GIT_DELTA_MODIFIED : GIT_DELTA_TYPECHANGE
        } else {
            record.old_file = absentSide(record.old_file)
            record.nfiles = 1
            record.status = GIT_DELTA_ADDED
        }
        delta.pointee = record
    }

    /// The merge copies the tree-to-index status onto the work-tree
    /// file. A staged symlink whose work tree is a regular file again
    /// would stay `T` with two file modes; `git diff-index` prints `M`.
    private static func relabelMergedTypeChange(_ delta: UnsafeMutablePointer<git_diff_delta>) {
        var record = delta.pointee
        let oldPresent = diffSideExists(record.old_file)
        let newPresent = diffSideExists(record.new_file)
        if oldPresent && newPresent {
            if diffModeType(record.old_file.mode) == diffModeType(record.new_file.mode) {
                record.status = GIT_DELTA_MODIFIED
            }
        } else if oldPresent {
            record.status = GIT_DELTA_DELETED
            record.nfiles = 1
        } else if newPresent {
            record.status = GIT_DELTA_ADDED
            record.nfiles = 1
        } else {
            record.status = GIT_DELTA_UNMODIFIED
        }
        delta.pointee = record
    }

    /// `git diff-index` uses `T` only when this changes. 100644 and
    /// 100755 are the same type.
    static func diffModeType(_ mode: UInt16) -> UInt16 {
        mode & 0o170000
    }

    private static func diffSideExists(_ file: git_diff_file) -> Bool {
        file.mode != 0 && file.flags & UInt32(GIT_DIFF_FLAG_EXISTS.rawValue) != 0
    }

    static func treeFile(_ tree: OpaquePointer?, path: UnsafePointer<CChar>) throws -> DiffIndexTreeFile? {
        guard let tree else { return nil }
        var entry: OpaquePointer?
        let rc = git_tree_entry_bypath(&entry, tree, path)
        defer { git_tree_entry_free(entry) }
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        guard let found = entry else { return nil }
        let mode = UInt16(truncatingIfNeeded: git_tree_entry_filemode(found).rawValue)
        guard let id = git_tree_entry_id(found) else { return nil }
        return DiffIndexTreeFile(mode: mode, id: id.pointee)
    }

    static func treeSide(_ side: git_diff_file, file: DiffIndexTreeFile) -> git_diff_file {
        var side = side
        side.mode = file.mode
        side.id = file.id
        side.flags |= UInt32(GIT_DIFF_FLAG_VALID_ID.rawValue) | UInt32(GIT_DIFF_FLAG_EXISTS.rawValue)
        side.id_abbrev = 40
        return side
    }

    static func absentSide(_ side: git_diff_file) -> git_diff_file {
        var side = side
        side.mode = 0
        side.id = git_oid()
        side.size = 0
        side.flags = UInt32(GIT_DIFF_FLAG_VALID_ID.rawValue)
        side.id_abbrev = 40
        return side
    }

    private static func diffIndexEntries(_ diff: OpaquePointer?) -> [DiffIndexEntry] {
        let count = git_diff_num_deltas(diff)
        var entries: [DiffIndexEntry] = []
        entries.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let delta = git_diff_get_delta(diff, index)?.pointee,
                  let entry = DiffIndexEntry(delta: delta) else { continue }
            entries.append(entry)
        }
        return entries
    }
}

/// One path from ``GitClient/diffIndex(ref:cached:refresh:)``.
///
/// Modes are the same bits `git diff-index` prints in octal (`0o100644`
/// for a regular file, `0` when that side does not exist). Ids are 40
/// hex digits. `sourcePath` and `destinationPath` differ when `status`
/// is a rename or a copy.
public struct DiffIndexEntry: Sendable, Equatable {
    public let oldMode: UInt32
    public let newMode: UInt32
    public let oldOID: String
    public let newOID: String
    /// `A`, `D`, `M`, `T`, `U`, `R` or `C`, as in `git diff-index` raw output.
    public let status: Character
    /// Rename or copy similarity, 0...100, the digits git prints after `R` or `C`.
    public let similarity: Int?
    public let sourcePath: String
    public let destinationPath: String

    public init(
        oldMode: UInt32,
        newMode: UInt32,
        oldOID: String,
        newOID: String,
        status: Character,
        similarity: Int? = nil,
        sourcePath: String,
        destinationPath: String
    ) {
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldOID = oldOID
        self.newOID = newOID
        self.status = status
        self.similarity = similarity
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }

    fileprivate init?(delta: git_diff_delta) {
        guard let status = Self.letter(delta.status) else { return nil }
        let oldPath = delta.old_file.path.map { String(cString: $0) } ?? ""
        let newPath = delta.new_file.path.map { String(cString: $0) } ?? ""
        let source = oldPath.isEmpty ? newPath : oldPath
        let destination = newPath.isEmpty ? source : newPath
        let scored = status == "R" || status == "C"
        self.init(
            oldMode: UInt32(delta.old_file.mode),
            newMode: UInt32(delta.new_file.mode),
            oldOID: Self.oid(delta.old_file),
            newOID: Self.oid(delta.new_file),
            status: status,
            similarity: scored ? Int(delta.similarity) : nil,
            sourcePath: source,
            destinationPath: destination)
    }

    /// Forty zeros when libgit2 has not hashed that side (`GIT_DIFF_FLAG_VALID_ID` clear).
    private static func oid(_ file: git_diff_file) -> String {
        guard file.flags & UInt32(GIT_DIFF_FLAG_VALID_ID.rawValue) != 0 else {
            return String(repeating: "0", count: 40)
        }
        var file = file
        return String(cString: git_oid_tostr_s(&file.id))
    }

    private static func letter(_ status: git_delta_t) -> Character? {
        switch status {
        case GIT_DELTA_ADDED: return "A"
        case GIT_DELTA_DELETED: return "D"
        case GIT_DELTA_MODIFIED: return "M"
        case GIT_DELTA_RENAMED: return "R"
        case GIT_DELTA_COPIED: return "C"
        case GIT_DELTA_TYPECHANGE: return "T"
        case GIT_DELTA_CONFLICTED: return "U"
        default: return nil
        }
    }
}
