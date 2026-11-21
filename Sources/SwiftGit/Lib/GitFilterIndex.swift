import Foundation
import CGitKit

/// Undo checkout's stat-cache update for empty output from a deferred failure.
/// Blob IDs, stages, modes and unrelated entries remain as checkout wrote them.
enum GitFilterIndex {
    static func invalidate(_ failedPaths: [URL: Set<String>]) throws {
        for (directory, paths) in failedPaths {
            var repo: OpaquePointer?
            try GitClient.check(git_repository_open(&repo, directory.path))
            defer { git_repository_free(repo) }
            var index: OpaquePointer?
            try GitClient.check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            var changed = false
            for path in paths {
                guard let entry = git_index_get_bypath(index, path, 0) else { continue }
                var copy = entry.pointee
                copy.ctime = git_index_time()
                copy.mtime = git_index_time()
                copy.dev = 0
                copy.ino = 0
                copy.uid = 0
                copy.gid = 0
                copy.file_size = 0
                try path.withCString { name in
                    copy.path = name
                    try GitClient.check(git_index_add(index, &copy))
                }
                changed = true
            }
            if changed { try GitClient.check(git_index_write(index)) }
        }
    }
}
