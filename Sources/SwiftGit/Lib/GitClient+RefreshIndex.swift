import Foundation
import CGitKit
import ShellKit

extension GitClient {
    /// Apply the stat-refresh operation of `git update-index -q --refresh`
    /// to the given repository-relative paths, like `git add --refresh -- <paths>`.
    /// Positional operands to `update-index` also stage content. Content is
    /// hashed through clean filters without writing objects;
    /// the index's OIDs, modes and stages stay.
    /// Unmerged, missing, skip-worktree and assume-unchanged entries are skipped.
    ///
    /// With no LFS filter registered, a smudged LFS file stays stale, exactly
    /// as `git update-index --refresh` without git-lfs would leave it.
    public func refreshIndex(paths: [String]) async throws {
        let urls = try await withRepository { repository in
            let repo = try Self.refreshIndexHandle(repository)
            var urls: [URL] = []
            if let directory = git_repository_path(repo) {
                urls.append(URL(fileURLWithPath: String(cString: directory))
                    .appendingPathComponent("index").standardizedFileURL)
            }
            for path in paths {
                if let full = DiffIndexStat.worktreePath(repo, path) {
                    urls.append(URL(fileURLWithPath: full).standardizedFileURL)
                }
            }
            return urls
        }
        // Finish all authorizations before opening the index or statting even
        // the first file: a later denial must not allow a partial refresh.
        for url in urls { try await Shell.authorize(url) }
        // Index lookup may match a case alias. Resolve it before authorizing
        // the actual work-tree path, and keep that spelling for filter lookup
        // and the stat rewrite as well as for the file read.
        let resolved = try await withRepository { repository in
            let repo = try Self.refreshIndexHandle(repository)
            var index: OpaquePointer?
            try Self.check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            var storedPaths: [String] = []
            var storedURLs: [URL] = []
            for path in paths {
                guard let entry = git_index_get_bypath(index, path, 0)?.pointee,
                      let name = entry.path else { continue }
                let stored = String(cString: name)
                guard let full = DiffIndexStat.worktreePath(repo, stored) else { continue }
                storedPaths.append(stored)
                storedURLs.append(URL(fileURLWithPath: full).standardizedFileURL)
            }
            return (paths: storedPaths, urls: storedURLs)
        }
        for url in resolved.urls { try await Shell.authorize(url) }
        try await withRepository { repository in
            try Self.refreshIndex(resolved.paths, repo: Self.refreshIndexHandle(repository))
        }
    }

    private static func refreshIndexHandle(_ repository: Repository) throws -> OpaquePointer {
        guard let repo = handle(of: repository) else {
            throw Libgit2Error(
                code: -1, klass: Int32(GIT_ERROR_REPOSITORY.rawValue),
                message: "cannot reach GitKit's repository handle to refresh the index")
        }
        return repo
    }

    private static func refreshIndex(_ paths: [String], repo: OpaquePointer) throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        let fileMode = DiffIndexStat.flag("core.filemode", repo: repo, default: DiffIndexStat.defaultFileMode)
        let trustCtime = DiffIndexStat.flag("core.trustctime", repo: repo, default: true)
        let symlinks = DiffIndexStat.flag("core.symlinks", repo: repo, default: true)
        var changed = false
        for path in paths {
            guard let entry = git_index_get_bypath(index, path, 0)?.pointee,
                  let stored = entry.path, String(cString: stored) == path else { continue }
            if entry.flags & 0x8000 != 0 || entry.flags_extended & DiffIndexStat.skipWorktree != 0 { continue }
            guard let location = DiffIndexStat.worktreePath(repo, path),
                  let file = DiffIndexWorktree.fileStat(location) else { continue }
            let linkPlaceholder = entry.mode == 0o120000 && !symlinks && file.mode & 0o170000 == 0o100000
            guard linkPlaceholder || DiffIndexStat.modesMatch(
                index: entry.mode, work: file.mode, trustFileMode: fileMode) else {
                continue
            }
            if entry.file_size == UInt32(truncatingIfNeeded: file.size)
                && !DiffIndexStat.statDiffers(entry, file, trustCtime: trustCtime) {
                continue
            }
            let oid: git_oid
            if entry.mode == 0o120000 {
                // Hash a link or its core.symlinks=false placeholder as raw
                // target text. Neither representation runs a clean filter.
                guard let targetOID = DiffIndexStat.rawOID(file, at: location) else { continue }
                oid = targetOID
            } else {
                oid = try Self.filteredOID(repo: repo, path: path, location: location)
            }
            guard DiffIndexStat.oidEqual(oid, entry.id) else { continue }
            DiffIndexStat.rewriteStat(index, path: path, file: file)
            changed = true
        }
        if changed { try check(git_index_write(index)) }
    }

    /// Hash a work-tree file through its clean filters without writing an object.
    /// `GIT_FILTER_ALLOW_UNSAFE` matches git's refresh hash (no `HASH_WRITE_OBJECT`),
    /// so `core.safecrlf=true` does not reject mixed line endings while required
    /// and other clean-filter failures still propagate.
    private static func filteredOID(repo: OpaquePointer, path: String, location: String) throws -> git_oid {
        var filters: OpaquePointer?
        try check(git_filter_list_load(
            &filters, repo, nil, path, GIT_FILTER_TO_ODB, UInt32(GIT_FILTER_ALLOW_UNSAFE.rawValue)))
        defer { git_filter_list_free(filters) }
        var oid = git_oid()
        guard let filters else {
            try check(location.withCString { git_odb_hashfile(&oid, $0, GIT_OBJECT_BLOB) })
            return oid
        }
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }
        try check(git_filter_list_apply_to_file(&buffer, filters, repo, path))
        if let ptr = buffer.ptr, buffer.size > 0 {
            try check(git_odb_hash(&oid, ptr, buffer.size, GIT_OBJECT_BLOB))
        } else {
            var byte: UInt8 = 0
            try check(git_odb_hash(&oid, &byte, 0, GIT_OBJECT_BLOB))
        }
        return oid
    }
}
