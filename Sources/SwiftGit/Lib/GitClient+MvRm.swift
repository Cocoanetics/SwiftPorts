import Foundation
import ForgeKit
import libgit2
import ShellKit

extension GitClient {

    /// Remove `paths` from the index. With `keepWorktree == false`
    /// (real git's default `git rm`), also delete the files on disk.
    /// `force == true` skips the "uncommitted changes" safety check.
    public func remove(paths: [String], keepWorktree: Bool = false, force: Bool = false) async throws {
        guard !paths.isEmpty else { return }
        // Authorize every worktree URL up front. Index-only removals
        // (`--cached`) skip disk I/O, but rejecting the call before
        // mutating the index keeps `git rm` atomic from the embedder's
        // perspective: either every path is touchable or none is.
        if !keepWorktree {
            let cwd = workingDirectory
            for path in paths {
                try await Shell.authorize(cwd.appendingPathComponent(path))
            }
        }
        try await withRepository { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }

            for path in paths {
                try check(path.withCString { p in
                    git_index_remove_bypath(index, p)
                })
            }
            try check(git_index_write(index))

            if !keepWorktree {
                let cwd = workingDirectory
                let fm = FileManager.default
                for path in paths {
                    let full = cwd.appendingPathComponent(path)
                    try? fm.removeItem(at: full)
                }
            }
            _ = force  // currently we trust the caller; safety check is a future addition
        }
    }

    /// Move / rename `source` to `destination`. Stages the move in
    /// the index and on disk. Equivalent to `git mv`.
    public func move(from source: String, to destination: String) async throws {
        // Resolve absolute paths in the workdir.
        let cwd = workingDirectory
        let srcURL = cwd.appendingPathComponent(source)
        let dstURL = cwd.appendingPathComponent(destination)
        // Gate both endpoints through the active sandbox before
        // touching either side of the move (libgit2 would surface a
        // generic error if we let the FS call fail mid-rename).
        try await Shell.authorize(srcURL)
        try await Shell.authorize(dstURL)
        try await withRepository { repo in
            guard FileManager.default.fileExists(atPath: srcURL.path) else {
                throw Libgit2Error(code: -1, klass: 0,
                    message: "bad source, source=\(source) does not exist")
            }

            // Move on disk.
            try FileManager.default.moveItem(at: srcURL, to: dstURL)

            // Update the index: remove old path, add new path.
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            try check(source.withCString { p in
                git_index_remove_bypath(index, p)
            })
            try check(destination.withCString { p in
                git_index_add_bypath(index, p)
            })
            try check(git_index_write(index))
        }
    }
}
