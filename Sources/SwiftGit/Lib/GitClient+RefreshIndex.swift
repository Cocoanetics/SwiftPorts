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
        try await withRepository { repository in
            try Self.refreshIndex(paths, repo: Self.refreshIndexHandle(repository))
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
            guard let entry = git_index_get_bypath(index, path, 0)?.pointee else { continue }
            if entry.flags & 0x8000 != 0 || entry.flags_extended & DiffIndexStat.skipWorktree != 0 { continue }
            guard let location = DiffIndexStat.worktreePath(repo, path),
                  let file = DiffIndexWorktree.fileStat(location) else { continue }
            let linkPlaceholder = entry.mode == 0o120000 && !symlinks && file.mode & 0o170000 == 0o100000
            guard linkPlaceholder || DiffIndexStat.modesMatch(
                index: entry.mode, work: file.mode, trustFileMode: fileMode) else {
                continue
            }
            if UInt64(entry.file_size) == file.size && !DiffIndexStat.statDiffers(entry, file, trustCtime: trustCtime) {
                continue
            }
            let oid: git_oid
            if entry.mode == 0o120000 {
                // Hash a link or its core.symlinks=false placeholder as raw
                // target text. Neither representation runs a clean filter.
                guard let targetOID = DiffIndexStat.rawOID(file, at: location) else { continue }
                oid = targetOID
            } else {
                var filtered = git_oid()
                try check(git_repository_hashfile(&filtered, repo, location, GIT_OBJECT_BLOB, path))
                oid = filtered
            }
            guard DiffIndexStat.oidEqual(oid, entry.id) else { continue }
            try DiffIndexStat.rewriteStat(index, path: path, file: file)
            changed = true
        }
        if changed { try check(git_index_write(index)) }
    }
}
