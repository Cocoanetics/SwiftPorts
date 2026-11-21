import Foundation
import CGitKit
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

/// Stat handling for an uncached `diffIndex`.
///
/// libgit2 hashes a same-size stat mismatch (`GIT_DIFF` would also pass
/// the bytes through a clean filter) and drops the file when that oid
/// matches. `git diff-index` does not hash it, so the file stays, with a
/// zero new id. Poking the in-memory index size onto a different non-zero
/// value forces the size-mismatch path, which reports the file and does
/// not hash. A racily-clean smudge stores `file_size` 0 for a non-empty
/// file and is the same case: libgit2 would hash it. The poke is undone
/// before anything is written.
///
/// `refresh` instead rewrites stat metadata when the raw work-tree bytes
/// match the stage-zero blob, then writes the index once. `GIT_DIFF_UPDATE_INDEX`
/// is not used: it hashes with `GIT_FILTER_TO_ODB` and would refresh a
/// file whose filtered oid matches even when the raw bytes do not.
/// The write happens after the diff. Writing first would make libgit2
/// reload the index and discard the poke.
enum DiffIndexStat {
    /// `GIT_INDEX_ENTRY_SKIP_WORKTREE` (`flags_extended` bit 14).
    private static let skipWorktree: UInt16 = 1 << 14
    #if os(Windows)
    private static let defaultFileMode = false
    #else
    private static let defaultFileMode = true
    #endif

    final class Hold {
        let index: OpaquePointer
        var poked: [String: UInt32]
        var refreshed: Bool
        private var released = false

        init(index: OpaquePointer, poked: [String: UInt32], refreshed: Bool) {
            self.index = index
            self.poked = poked
            self.refreshed = refreshed
        }

        /// Put poked sizes back, then persist stat updates. A refresh that
        /// changed nothing does not rewrite the index.
        func persist(refresh: Bool) throws {
            for (path, size) in poked {
                guard let entry = git_index_get_bypath(index, path, 0) else { continue }
                UnsafeMutablePointer(mutating: entry).pointee.file_size = size
            }
            if refresh && refreshed {
                try GitClient.check(git_index_write(index))
            }
        }

        func discard() {
            guard !released else { return }
            released = true
            git_index_free(index)
        }
    }

    private struct Rules {
        var refresh: Bool
        var trustFileMode: Bool
        var trustCtime: Bool
    }

    fileprivate struct WorktreeStat {
        var mode: UInt32
        var size: UInt64
        var mtimeSeconds: Int64
        var mtimeNanoseconds: UInt32
        var ctimeSeconds: Int64
        var ctimeNanoseconds: UInt32
        var dev: UInt32
        var ino: UInt32
        var uid: UInt32
        var gid: UInt32
    }

    private struct Candidate: Hashable {
        var status: Int32
        var source: String
        var destination: String
    }

    static func prepare(_ repo: OpaquePointer?, refresh: Bool) throws -> Hold {
        var index: OpaquePointer?
        try GitClient.check(git_repository_index(&index, repo))
        guard let index else {
            throw Libgit2Error(
                code: -1, klass: Int32(GIT_ERROR_INDEX.rawValue),
                message: "cannot open the index to refresh stat metadata")
        }
        let rules = Rules(
            refresh: refresh,
            trustFileMode: flag("core.filemode", repo: repo, default: defaultFileMode),
            trustCtime: flag("core.trustctime", repo: repo, default: true))
        var poked: [String: UInt32] = [:]
        var refreshed = false
        do {
            for path in readablePaths(index) {
                try consider(
                    index, repo: repo, path: path, rules: rules,
                    poked: &poked, refreshed: &refreshed)
            }
        } catch {
            git_index_free(index)
            throw error
        }
        return Hold(index: index, poked: poked, refreshed: refreshed)
    }

    static func inputURLs(_ repo: OpaquePointer?, index: OpaquePointer?) -> [URL] {
        var urls: [URL] = []
        if let path = git_index_path(index) {
            urls.append(URL(fileURLWithPath: String(cString: path)).standardizedFileURL)
        }
        for relative in readablePaths(index) {
            guard let full = worktreePath(repo, relative) else { continue }
            urls.append(URL(fileURLWithPath: full).standardizedFileURL)
        }
        return urls
    }

    /// Discover worktree destinations before libgit2's rename detection or
    /// our raw-id realization can read them. Even unpaired additions are hashed
    /// when a source exists. This pass inspects metadata without opening files.
    static func renameInputURLs(_ diff: OpaquePointer?, repo: OpaquePointer?) -> [URL] {
        let count = git_diff_num_deltas(diff)
        let hasSource = (0..<count).contains { offset in
            guard let status = git_diff_get_delta(diff, offset)?.pointee.status else { return false }
            return status == GIT_DELTA_DELETED || status == GIT_DELTA_RENAMED
        }
        guard hasSource else { return [] }
        return (0..<count).compactMap { offset in
            guard let delta = git_diff_get_delta(diff, offset)?.pointee,
                  delta.status == GIT_DELTA_ADDED || delta.status == GIT_DELTA_RENAMED,
                  let path = delta.new_file.path,
                  let full = worktreePath(repo, String(cString: path)) else { return nil }
            return URL(fileURLWithPath: full).standardizedFileURL
        }
    }

    /// Rewrite deltas whose raw work-tree bytes match stage zero so rename
    /// detection does not see a stat-only touch as an add or a type change.
    /// Returns whether that changed the add/delete/type-change set.
    static func correct(
        _ diff: OpaquePointer?, repo: OpaquePointer?, tree: OpaquePointer?
    ) throws -> Bool {
        let before = candidateKeys(diff)
        var index: OpaquePointer?
        try GitClient.check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        let rules = Rules(
            refresh: true,
            trustFileMode: flag("core.filemode", repo: repo, default: defaultFileMode),
            trustCtime: true)
        let count = git_diff_num_deltas(diff)
        for offset in 0..<count {
            guard let pointer = git_diff_get_delta(diff, offset) else { continue }
            try correctOne(
                UnsafeMutablePointer(mutating: pointer),
                index: index, repo: repo, tree: tree, rules: rules)
        }
        return candidateKeys(diff) != before
    }

    /// Git's exact-rename pass hashes every addition when a source exists,
    /// including destinations it cannot pair. Keep those raw ids even though
    /// hashing a work-tree candidate does not store its blob in the ODB.
    static func realizeRenames(_ diff: OpaquePointer?, repo: OpaquePointer?) {
        let count = git_diff_num_deltas(diff)
        let hasSource = (0..<count).contains { offset in
            guard let status = git_diff_get_delta(diff, offset)?.pointee.status else { return false }
            return status == GIT_DELTA_DELETED || status == GIT_DELTA_RENAMED
        }
        let valid = UInt32(GIT_DIFF_FLAG_VALID_ID.rawValue)
        let exists = UInt32(GIT_DIFF_FLAG_EXISTS.rawValue)
        for offset in 0..<count {
            guard let pointer = git_diff_get_delta(diff, offset) else { continue }
            let delta = UnsafeMutablePointer(mutating: pointer)
            let status = delta.pointee.status
            guard status == GIT_DELTA_RENAMED || (hasSource && status == GIT_DELTA_ADDED) else { continue }
            guard oidIsZero(delta.pointee.new_file.id) else { continue }
            guard let pathPointer = delta.pointee.new_file.path else { continue }
            let path = String(cString: pathPointer)
            guard let location = worktreePath(repo, path),
                  let file = DiffIndexWorktree.fileStat(location),
                  let oid = rawOID(file, at: location) else { continue }
            var record = delta.pointee
            record.new_file.id = oid
            record.new_file.flags |= valid | exists
            record.new_file.id_abbrev = 40
            delta.pointee = record
        }
    }

    private static func consider(
        _ index: OpaquePointer?,
        repo: OpaquePointer?,
        path: String,
        rules: Rules,
        poked: inout [String: UInt32],
        refreshed: inout Bool
    ) throws {
        guard let entry = git_index_get_bypath(index, path, 0)?.pointee else { return }
        guard let location = worktreePath(repo, path), let file = DiffIndexWorktree.fileStat(location) else { return }
        guard modesMatch(index: entry.mode, work: file.mode, trustFileMode: rules.trustFileMode) else { return }
        // Size 0 on a non-empty file is the racily-clean smudge, not a
        // content change. A newer mtime is ordinary stat dirt and is not
        // special: both are refreshed or poked below.
        let smudged = entry.file_size == 0 && file.size != 0
        if !smudged {
            guard file.size == UInt64(entry.file_size) else { return }
            guard statDiffers(entry, file, trustCtime: rules.trustCtime) else { return }
        }
        if rules.refresh {
            guard let oid = rawOID(file, at: location) else { return }
            if oidEqual(oid, entry.id) {
                rewriteStat(index, path: path, file: file)
                refreshed = true
                return
            }
        }
        poke(index, path: path, workSize: file.size, poked: &poked)
    }

    private static func correctOne(
        _ delta: UnsafeMutablePointer<git_diff_delta>,
        index: OpaquePointer?,
        repo: OpaquePointer?,
        tree: OpaquePointer?,
        rules: Rules
    ) throws {
        switch delta.pointee.status {
        case GIT_DELTA_DELETED, GIT_DELTA_CONFLICTED, GIT_DELTA_UNMODIFIED:
            return
        default:
            break
        }
        guard let pathPointer = delta.pointee.new_file.path else { return }
        let path = String(cString: pathPointer)
        guard let entry = git_index_get_bypath(index, path, 0)?.pointee else { return }
        if entry.flags & 0x3000 != 0 || entry.flags_extended & skipWorktree != 0 { return }
        guard let location = worktreePath(repo, path), let file = DiffIndexWorktree.fileStat(location) else { return }
        guard modesMatch(index: entry.mode, work: file.mode, trustFileMode: rules.trustFileMode) else { return }
        guard let oid = rawOID(file, at: location), oidEqual(oid, entry.id) else { return }
        if alreadyIndexShaped(delta.pointee, oid: entry.id, mode: entry.mode) { return }
        try rewrite(delta, path: pathPointer, oid: entry.id, mode: entry.mode, tree: tree)
    }

    /// A post-detection rename already carries the index blob. Leaving it
    /// alone keeps `-M` from being undone; a rebuild handles any record
    /// this pass still has to change.
    private static func alreadyIndexShaped(_ delta: git_diff_delta, oid: git_oid, mode: UInt32) -> Bool {
        let valid = UInt32(GIT_DIFF_FLAG_VALID_ID.rawValue)
        guard delta.new_file.flags & valid != 0 else { return false }
        return oidEqual(delta.new_file.id, oid) && UInt32(delta.new_file.mode) == mode
    }

    private static func rewrite(
        _ delta: UnsafeMutablePointer<git_diff_delta>,
        path: UnsafePointer<CChar>,
        oid: git_oid,
        mode: UInt32,
        tree: OpaquePointer?
    ) throws {
        var record = delta.pointee
        let indexMode = UInt16(truncatingIfNeeded: mode)
        if let old = try GitClient.treeFile(tree, path: path),
           oidEqual(old.id, oid), old.mode == indexMode {
            record.status = GIT_DELTA_UNMODIFIED
            delta.pointee = record
            return
        }
        record.new_file.id = oid
        record.new_file.mode = indexMode
        record.new_file.flags |= UInt32(GIT_DIFF_FLAG_VALID_ID.rawValue)
            | UInt32(GIT_DIFF_FLAG_EXISTS.rawValue)
        record.new_file.id_abbrev = 40
        if let old = try GitClient.treeFile(tree, path: path) {
            record.old_file = GitClient.treeSide(record.old_file, file: old)
            record.nfiles = 2
            record.status = GitClient.diffModeType(old.mode) == GitClient.diffModeType(indexMode)
                ? GIT_DELTA_MODIFIED : GIT_DELTA_TYPECHANGE
        } else {
            record.old_file = GitClient.absentSide(record.old_file)
            record.nfiles = 1
            record.status = GIT_DELTA_ADDED
        }
        delta.pointee = record
    }

    private static func candidateKeys(_ diff: OpaquePointer?) -> Set<Candidate> {
        var keys = Set<Candidate>()
        let count = git_diff_num_deltas(diff)
        for offset in 0..<count {
            guard let delta = git_diff_get_delta(diff, offset)?.pointee else { continue }
            switch delta.status {
            case GIT_DELTA_ADDED, GIT_DELTA_DELETED, GIT_DELTA_TYPECHANGE:
                let source = delta.old_file.path.map { String(cString: $0) } ?? ""
                let destination = delta.new_file.path.map { String(cString: $0) } ?? ""
                let status = Int32(delta.status.rawValue)
                keys.insert(Candidate(status: status, source: source, destination: destination))
            default:
                break
            }
        }
        return keys
    }

    /// Stage-zero files a refresh may stat. Conflicts, skip-worktree,
    /// assume-unchanged, and gitlinks are left to the diff as they are.
    private static func readablePaths(_ index: OpaquePointer?) -> [String] {
        var paths: [String] = []
        let count = git_index_entrycount(index)
        for offset in 0..<count {
            guard let entry = git_index_get_byindex(index, offset)?.pointee else { continue }
            if entry.flags & 0x3000 != 0 || entry.flags & 0x8000 != 0 { continue }
            if entry.flags_extended & skipWorktree != 0 { continue }
            let kind = entry.mode & 0o170000
            if kind == 0o160000 || kind == 0o040000 { continue }
            guard let path = entry.path else { continue }
            paths.append(String(cString: path))
        }
        return paths
    }

    private static func worktreePath(_ repo: OpaquePointer?, _ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("\\") else { return nil }
        guard !path.split(separator: "/").contains("..") else { return nil }
        guard let rootPointer = git_repository_workdir(repo) else { return nil }
        var root = String(cString: rootPointer)
        #if os(Windows)
        let relative = path.replacingOccurrences(of: "/", with: "\\")
        if !root.hasSuffix("\\") && !root.hasSuffix("/") { root.append("\\") }
        return root + relative
        #else
        if !root.hasSuffix("/") { root.append("/") }
        return root + path
        #endif
    }

    private static func rewriteStat(_ index: OpaquePointer?, path: String, file: WorktreeStat) {
        guard let current = git_index_get_bypath(index, path, 0) else { return }
        // Only stat data changes; git_index_add would revalidate the existing
        // OID and reject a missing blob that git update-index --refresh accepts.
        // Mark it up-to-date just as index_insert does, without replacing it.
        let entry = UnsafeMutablePointer(mutating: current)
        apply(file, to: &entry.pointee)
        entry.pointee.flags_extended |= UInt16(GIT_INDEX_ENTRY_UPTODATE.rawValue)
    }

    private static func apply(_ file: WorktreeStat, to entry: inout git_index_entry) {
        entry.ctime.seconds = Int32(truncatingIfNeeded: file.ctimeSeconds)
        entry.ctime.nanoseconds = file.ctimeNanoseconds
        entry.mtime.seconds = Int32(truncatingIfNeeded: file.mtimeSeconds)
        entry.mtime.nanoseconds = file.mtimeNanoseconds
        #if !os(Windows)
        entry.dev = file.dev
        #endif
        entry.ino = file.ino
        entry.uid = file.uid
        entry.gid = file.gid
        entry.file_size = UInt32(truncatingIfNeeded: file.size)
    }

    /// Remember the real size and store a different non-zero one so the
    /// work-tree comparison does not hash the file. The stand-in must
    /// not equal the work tree, or a smudged one-byte file looks clean.
    private static func poke(
        _ index: OpaquePointer?, path: String, workSize: UInt64, poked: inout [String: UInt32]
    ) {
        guard poked[path] == nil, let entry = git_index_get_bypath(index, path, 0) else { return }
        let original = entry.pointee.file_size
        UnsafeMutablePointer(mutating: entry).pointee.file_size = workSize == 1 ? 2 : 1
        poked[path] = original
    }

    private static func modesMatch(index: UInt32, work: UInt32, trustFileMode: Bool) -> Bool {
        let indexType = index & 0o170000
        let workType = work & 0o170000
        if indexType != workType { return false }
        if !trustFileMode && indexType == 0o100000 { return true }
        return index == work
    }

    private static func statDiffers(_ entry: git_index_entry, _ file: WorktreeStat, trustCtime: Bool) -> Bool {
        if entry.mtime.seconds != Int32(truncatingIfNeeded: file.mtimeSeconds) { return true }
        if entry.mtime.nanoseconds != file.mtimeNanoseconds { return true }
        if trustCtime {
            if entry.ctime.seconds != Int32(truncatingIfNeeded: file.ctimeSeconds) { return true }
            if entry.ctime.nanoseconds != file.ctimeNanoseconds { return true }
        }
        if entry.ino != file.ino || entry.uid != file.uid || entry.gid != file.gid { return true }
        return false
    }

    private static func rawOID(_ file: WorktreeStat, at path: String) -> git_oid? {
        var oid = git_oid()
        if file.mode == 0o120000 {
            guard let data = DiffIndexWorktree.bytes(path) else { return nil }
            let rc: Int32
            if data.isEmpty {
                var byte: UInt8 = 0
                rc = git_odb_hash(&oid, &byte, 0, GIT_OBJECT_BLOB)
            } else {
                rc = data.withUnsafeBytes { git_odb_hash(&oid, $0.baseAddress, $0.count, GIT_OBJECT_BLOB) }
            }
            return rc == 0 ? oid : nil
        }
        let rc = path.withCString { git_odb_hashfile(&oid, $0, GIT_OBJECT_BLOB) }
        return rc == 0 ? oid : nil
    }

    private static func oidEqual(_ lhs: git_oid, _ rhs: git_oid) -> Bool {
        var lhs = lhs
        var rhs = rhs
        return git_oid_equal(&lhs, &rhs) != 0
    }

    private static func oidIsZero(_ oid: git_oid) -> Bool {
        var oid = oid
        return git_oid_is_zero(&oid) != 0
    }

    private static func flag(_ name: String, repo: OpaquePointer?, default defaultValue: Bool) -> Bool {
        var config: OpaquePointer?
        guard git_repository_config(&config, repo) == 0 else { return defaultValue }
        defer { git_config_free(config) }
        var value: Int32 = 0
        let rc = name.withCString { git_config_get_bool(&value, config, $0) }
        guard rc == 0 else {
            git_error_clear()
            return defaultValue
        }
        return value != 0
    }

}

/// `lstat` (and the Windows attribute read libgit2's iterator uses) plus
/// the raw blob id of a work-tree file. Kept apart from ``DiffIndexStat``
/// so each type stays within the lint size limit.
private enum DiffIndexWorktree {
    static func fileStat(_ path: String) -> DiffIndexStat.WorktreeStat? {
        #if os(Windows)
        return windowsStat(path)
        #else
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0, let mode = gitMode(st.st_mode) else { return nil }
        #if canImport(Darwin)
        let mtime = st.st_mtimespec
        let ctime = st.st_ctimespec
        #else
        let mtime = st.st_mtim
        let ctime = st.st_ctim
        #endif
        return DiffIndexStat.WorktreeStat(
            mode: mode,
            size: UInt64(truncatingIfNeeded: st.st_size),
            mtimeSeconds: Int64(mtime.tv_sec),
            mtimeNanoseconds: UInt32(truncatingIfNeeded: mtime.tv_nsec),
            ctimeSeconds: Int64(ctime.tv_sec),
            ctimeNanoseconds: UInt32(truncatingIfNeeded: ctime.tv_nsec),
            dev: UInt32(truncatingIfNeeded: st.st_rdev),
            ino: UInt32(truncatingIfNeeded: st.st_ino),
            uid: UInt32(truncatingIfNeeded: st.st_uid),
            gid: UInt32(truncatingIfNeeded: st.st_gid))
        #endif
    }

    static func bytes(_ path: String) -> Data? {
        #if os(Windows)
        _ = path
        return nil
        #else
        var capacity = 128
        while capacity <= 1_048_576 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let read = buffer.withUnsafeMutableBufferPointer { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return path.withCString { readlink($0, base, capacity) }
            }
            if read < 0 { return nil }
            if read < capacity {
                let bytes = buffer.prefix(read).map { UInt8(bitPattern: $0) }
                return Data(bytes)
            }
            capacity *= 2
        }
        return nil
        #endif
    }

    #if !os(Windows)
    private static func gitMode(_ mode: mode_t) -> UInt32? {
        let type = mode & S_IFMT
        if type == S_IFREG {
            let executable = (mode & S_IXUSR) != 0 || (mode & S_IXGRP) != 0 || (mode & S_IXOTH) != 0
            return executable ? 0o100755 : 0o100644
        }
        if type == S_IFLNK { return 0o120000 }
        return nil
    }
    #endif

    #if os(Windows)
    private static func windowsStat(_ path: String) -> DiffIndexStat.WorktreeStat? {
        var data = WIN32_FILE_ATTRIBUTE_DATA()
        let found = path.withCString(encodedAs: UTF16.self) { name in
            withUnsafeMutablePointer(to: &data) { pointer in
                GetFileAttributesExW(name, GetFileExInfoStandard, UnsafeMutableRawPointer(pointer))
            }
        }
        guard found else { return nil }
        let attributes = data.dwFileAttributes
        if attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0 { return nil }
        if attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0 { return nil }
        let high = UInt64(data.nFileSizeHigh) << 32
        let size = high | UInt64(data.nFileSizeLow)
        let written = unix(data.ftLastWriteTime)
        let created = unix(data.ftCreationTime)
        return DiffIndexStat.WorktreeStat(
            mode: 0o100644, size: size,
            mtimeSeconds: written.seconds, mtimeNanoseconds: written.nanoseconds,
            ctimeSeconds: created.seconds, ctimeNanoseconds: created.nanoseconds,
            dev: 0, ino: 0, uid: 0, gid: 0)
    }

    private static func unix(_ time: FILETIME) -> (seconds: Int64, nanoseconds: UInt32) {
        let ticks = (UInt64(time.dwHighDateTime) << 32) | UInt64(time.dwLowDateTime)
        let epoch: UInt64 = 11_644_473_600 * 10_000_000
        guard ticks >= epoch else { return (0, 0) }
        let unixTicks = ticks - epoch
        return (Int64(unixTicks / 10_000_000), UInt32((unixTicks % 10_000_000) * 100))
    }
    #endif
}
