import Foundation
import ShellKit
import GitKit

// Sandbox-aware delegation onto the pure `Repository` mv/rm operations.
// The worktree paths each operation will touch are authorized here —
// before any index or filesystem mutation — so `git rm` / `git mv` stay
// atomic from the embedder's perspective: either every path is touchable
// or none is.
extension GitClient {

    /// Remove `paths` from the index (and, unless `keepWorktree`, from disk).
    public func remove(paths: [String], keepWorktree: Bool = false, force: Bool = false) async throws {
        guard !paths.isEmpty else { return }
        // Index-only removals (`--cached`) skip disk I/O, but rejecting the
        // call before mutating the index keeps the operation atomic.
        if !keepWorktree {
            let cwd = workingDirectory
            for path in paths {
                try await Shell.authorize(cwd.appendingPathComponent(path))
            }
        }
        try await withRepository {
            try $0.remove(paths: paths, keepWorktree: keepWorktree, force: force)
        }
    }

    /// Move / rename `source` to `destination`. Equivalent to `git mv`.
    public func move(from source: String, to destination: String) async throws {
        // Gate both endpoints through the active sandbox before
        // touching either side of the move (libgit2 would surface a
        // generic error if we let the FS call fail mid-rename).
        let cwd = workingDirectory
        try await Shell.authorize(cwd.appendingPathComponent(source))
        try await Shell.authorize(cwd.appendingPathComponent(destination))
        try await withRepository {
            try $0.move(from: source, to: destination)
        }
    }
}
