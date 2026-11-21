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

extension GitClient {

    /// Stat-only refresh of stage-0 index entries for `paths`, hashing each
    /// stat-dirty file through the repository's clean filters
    /// (`GIT_FILTER_TO_ODB`), matching `git update-index -q --refresh --stdin`.
    ///
    /// Pointer OIDs, modes, stages, and unrelated flags are never modified;
    /// the index is written once and only when at least one entry's stat cache
    /// was refreshed. Unmerged, missing, assume-unchanged, skip-worktree, and
    /// non-blob entries are skipped silently.
    public func refreshIndex(paths: [String]) async throws {
        var seen = Set<String>()
        let unique = paths.filter {
            RefreshIndexWorktree.isValidRelativePath($0) && seen.insert($0).inserted
        }
        guard !unique.isEmpty else { return }
        let urls = try await withRepository { repository in
            try Self.refreshIndexAuthorizationURLs(repository, paths: unique)
        }
        for url in urls {
            try await Shell.authorize(url)
        }
        try await withRepository { repository in
            try Self.performRefreshIndex(repository, paths: unique)
        }
    }

    /// Evaluate the `filter` git attribute for each repository-relative path,
    /// returning those entries whose `filter` attribute has a string value
    /// (for example `"lfs"`).
    public func filterAttribute(for paths: [String]) async throws -> [String: String] {
        var seen = Set<String>()
        let unique = paths.filter {
            RefreshIndexWorktree.isValidRelativePath($0) && seen.insert($0).inserted
        }
        guard !unique.isEmpty else { return [:] }
        let attrURLs = try await withFilterMetadataRepository { repository in
            try Self.attributeAuthorizationURLs(repository, paths: unique)
        }
        for url in attrURLs {
            try await Shell.authorize(url)
        }
        let noSystem = Shell.env("GIT_ATTR_NOSYSTEM") == "1"
        return try await withFilterMetadataRepository { repository in
            try Self.readFilterAttributes(repository, paths: unique, noSystem: noSystem)
        }
    }

    private static func refreshRepositoryHandle(_ repository: Repository) throws -> OpaquePointer {
        guard let repo = handle(of: repository) else {
            throw Libgit2Error(
                code: -1, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                message: "cannot reach GitKit's repository handle to refresh the index")
        }
        return repo
    }

    private static func refreshIndexAuthorizationURLs(
        _ repository: Repository, paths: [String]
    ) throws -> [URL] {
        let repo = try refreshRepositoryHandle(repository)
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
        var urls: [URL] = []
        if let indexPath = git_index_path(index) {
            urls.append(URL(fileURLWithPath: String(cString: indexPath)).standardizedFileURL)
        }
        for path in paths {
            guard git_index_get_bypath(index, path, 0) != nil,
                  let full = RefreshIndexWorktree.worktreePath(repo, path) else { continue }
            urls.append(URL(fileURLWithPath: full).standardizedFileURL)
        }
        return urls
    }

    private static func performRefreshIndex(_ repository: Repository, paths: [String]) throws {
        let repo = try refreshRepositoryHandle(repository)
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        try check(git_index_read(index, 0))
        let trustFileMode = RefreshIndexWorktree.flag(
            "core.filemode", repo: repo, default: RefreshIndexWorktree.defaultFileMode)
        let trustCtime = RefreshIndexWorktree.flag("core.trustctime", repo: repo, default: true)
        var changed = false
        for path in paths where refreshOneEntry(
            index: index, repo: repo, path: path,
            trustFileMode: trustFileMode, trustCtime: trustCtime
        ) {
            changed = true
        }
        if changed {
            try check(git_index_write(index))
        }
    }

    private static func refreshOneEntry(
        index: OpaquePointer?,
        repo: OpaquePointer?,
        path: String,
        trustFileMode: Bool,
        trustCtime: Bool
    ) -> Bool {
        guard let current = git_index_get_bypath(index, path, 0) else { return false }
        let entry = current.pointee
        if entry.flags & 0x3000 != 0 || entry.flags & 0x8000 != 0 { return false }
        if entry.flags_extended & RefreshIndexWorktree.skipWorktree != 0 { return false }
        let kind = entry.mode & 0o170000
        if kind == 0o160000 || kind == 0o040000 { return false }
        guard let location = RefreshIndexWorktree.worktreePath(repo, path),
              let file = RefreshIndexWorktree.fileStat(location) else { return false }
        guard RefreshIndexWorktree.modesMatch(
            index: entry.mode, work: file.mode, trustFileMode: trustFileMode) else { return false }
        let smudged = entry.file_size == 0 && file.size != 0
        if !smudged && file.size == UInt64(entry.file_size)
            && !RefreshIndexWorktree.statDiffers(entry, file, trustCtime: trustCtime) {
            return false
        }
        guard let oid = RefreshIndexWorktree.filteredOID(file, at: location, repo: repo, asPath: path),
              RefreshIndexWorktree.oidEqual(oid, entry.id) else {
            return false
        }
        let mutable = UnsafeMutablePointer(mutating: current)
        RefreshIndexWorktree.apply(file, to: &mutable.pointee)
        mutable.pointee.flags_extended |= UInt16(GIT_INDEX_ENTRY_UPTODATE.rawValue)
        return true
    }

    private static func attributeAuthorizationURLs(
        _ repository: Repository, paths: [String]
    ) throws -> [URL] {
        let repo = try refreshRepositoryHandle(repository)
        var urls: [URL] = []
        var seen = Set<URL>()
        func addIfPresent(_ url: URL) {
            let clean = url.standardizedFileURL
            guard seen.insert(clean).inserted,
                  FileManager.default.fileExists(atPath: clean.path) else { return }
            urls.append(clean)
        }
        if let gitDir = git_repository_path(repo) {
            let info = URL(fileURLWithPath: String(cString: gitDir))
                .appendingPathComponent("info/attributes")
            addIfPresent(info)
        }
        if let workdir = git_repository_workdir(repo) {
            let root = URL(fileURLWithPath: String(cString: workdir))
            addIfPresent(root.appendingPathComponent(".gitattributes"))
            for path in paths {
                var current = (path as NSString).deletingLastPathComponent
                while !current.isEmpty && current != "." {
                    addIfPresent(root.appendingPathComponent(current).appendingPathComponent(".gitattributes"))
                    let parent = (current as NSString).deletingLastPathComponent
                    if parent == current { break }
                    current = parent
                }
            }
        }
        return urls
    }

    private static func readFilterAttributes(
        _ repository: Repository, paths: [String], noSystem: Bool
    ) throws -> [String: String] {
        let repo = try refreshRepositoryHandle(repository)
        var flags = UInt32(GIT_ATTR_CHECK_FILE_THEN_INDEX)
        if noSystem { flags |= UInt32(GIT_ATTR_CHECK_NO_SYSTEM) }
        var result: [String: String] = [:]
        for path in paths {
            var value: UnsafePointer<CChar>?
            let rc = path.withCString { git_attr_get(&value, repo, flags, $0, "filter") }
            guard rc == 0 else {
                git_error_clear()
                continue
            }
            if let value, git_attr_value(value) == GIT_ATTR_VALUE_STRING {
                result[path] = String(cString: value)
            }
        }
        return result
    }
}

private enum RefreshIndexWorktree {
    static let skipWorktree: UInt16 = 1 << 14
    #if os(Windows)
    static let defaultFileMode = false
    #else
    static let defaultFileMode = true
    #endif

    struct WorktreeStat {
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

    static func isValidRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("\\")
            && !path.split(separator: "/").contains("..")
    }

    static func worktreePath(_ repo: OpaquePointer?, _ path: String) -> String? {
        guard isValidRelativePath(path),
              let rootPointer = git_repository_workdir(repo) else { return nil }
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

    static func apply(_ file: WorktreeStat, to entry: inout git_index_entry) {
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

    static func modesMatch(index: UInt32, work: UInt32, trustFileMode: Bool) -> Bool {
        let indexType = index & 0o170000
        let workType = work & 0o170000
        if indexType != workType { return false }
        if !trustFileMode && indexType == 0o100000 { return true }
        return index == work
    }

    static func statDiffers(_ entry: git_index_entry, _ file: WorktreeStat, trustCtime: Bool) -> Bool {
        if entry.mtime.seconds != Int32(truncatingIfNeeded: file.mtimeSeconds) { return true }
        if entry.mtime.nanoseconds != file.mtimeNanoseconds { return true }
        if trustCtime {
            if entry.ctime.seconds != Int32(truncatingIfNeeded: file.ctimeSeconds) { return true }
            if entry.ctime.nanoseconds != file.ctimeNanoseconds { return true }
        }
        #if !os(Windows)
        if entry.dev != file.dev { return true }
        #endif
        if entry.ino != file.ino || entry.uid != file.uid || entry.gid != file.gid { return true }
        return false
    }

    static func filteredOID(
        _ file: WorktreeStat, at location: String, repo: OpaquePointer?, asPath: String
    ) -> git_oid? {
        var oid = git_oid()
        if file.mode == 0o120000 {
            guard let data = readlinkBytes(location) else { return nil }
            let rc: Int32
            if data.isEmpty {
                var byte: UInt8 = 0
                rc = git_odb_hash(&oid, &byte, 0, GIT_OBJECT_BLOB)
            } else {
                rc = data.withUnsafeBytes { git_odb_hash(&oid, $0.baseAddress, $0.count, GIT_OBJECT_BLOB) }
            }
            return rc == 0 ? oid : nil
        }
        let rc = location.withCString { full in
            asPath.withCString { rel in
                git_repository_hashfile(&oid, repo, full, GIT_OBJECT_BLOB, rel)
            }
        }
        guard rc == 0 else {
            git_error_clear()
            return nil
        }
        return oid
    }

    static func oidEqual(_ lhs: git_oid, _ rhs: git_oid) -> Bool {
        var lhs = lhs
        var rhs = rhs
        return git_oid_equal(&lhs, &rhs) != 0
    }

    static func flag(_ name: String, repo: OpaquePointer?, default defaultValue: Bool) -> Bool {
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

    static func fileStat(_ path: String) -> WorktreeStat? {
        #if os(Windows)
        return windowsStat(path)
        #else
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0,
              let mode = gitMode(st.st_mode) else { return nil }
        #if canImport(Darwin)
        let mtime = st.st_mtimespec
        let ctime = st.st_ctimespec
        #else
        let mtime = st.st_mtim
        let ctime = st.st_ctim
        #endif
        return WorktreeStat(
            mode: mode,
            size: UInt64(truncatingIfNeeded: st.st_size),
            mtimeSeconds: Int64(mtime.tv_sec),
            mtimeNanoseconds: UInt32(truncatingIfNeeded: mtime.tv_nsec),
            ctimeSeconds: Int64(ctime.tv_sec),
            ctimeNanoseconds: UInt32(truncatingIfNeeded: ctime.tv_nsec),
            dev: UInt32(truncatingIfNeeded: st.st_dev),
            ino: UInt32(truncatingIfNeeded: st.st_ino),
            uid: UInt32(truncatingIfNeeded: st.st_uid),
            gid: UInt32(truncatingIfNeeded: st.st_gid))
        #endif
    }

    private static func readlinkBytes(_ path: String) -> Data? {
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
                return Data(buffer.prefix(read).map { UInt8(bitPattern: $0) })
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
    private static func windowsStat(_ path: String) -> WorktreeStat? {
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
        return WorktreeStat(
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
