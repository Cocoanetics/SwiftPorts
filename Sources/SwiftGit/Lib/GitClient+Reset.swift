import Foundation
import ForgeKit
import libgit2

/// Mode for whole-tree resets. Mirrors libgit2's `git_reset_t` 1:1.
public enum ResetMode: Sendable {
    case soft   // move HEAD only
    case mixed  // move HEAD + reset index (default)
    case hard   // move HEAD + reset index + reset working tree

    fileprivate var raw: git_reset_t {
        switch self {
        case .soft: return GIT_RESET_SOFT
        case .mixed: return GIT_RESET_MIXED
        case .hard: return GIT_RESET_HARD
        }
    }
}

/// Result of a `git reset` invocation. The CLI uses this to format
/// real-git's role-specific output:
/// - `--hard` prints `HEAD is now at <sha7> <subject>`.
/// - `--mixed`/`--soft` are silent on success.
/// - per-path form prints `Unstaged changes after reset:` + a status
///   summary (currently we just print the header — full status takes
///   a separate impl).
public enum ResetOutcome: Sendable {
    case wholeTree(targetSHA: String, shortSHA: String, subject: String, mode: ResetMode)
    case paths([String])
}

extension GitClient {

    /// Reset HEAD (and optionally the index + working tree) to `target`.
    /// Equivalent to `git reset [--soft|--mixed|--hard] [<commit>]`.
    @discardableResult
    public func reset(
        to target: String = "HEAD",
        mode: ResetMode = .mixed
    ) async throws -> ResetOutcome {
        try await withRepository { repo in
            var object: OpaquePointer?
            try check(git_revparse_single(&object, repo, target))
            defer { git_object_free(object) }

            try check(git_reset(repo, object, mode.raw, nil))

            // Pull the resulting HEAD's first message line for the
            // `HEAD is now at` summary.
            let oidPtr = git_object_id(object)
            var oid = oidPtr?.pointee ?? git_oid()
            let sha = formatOID(&oid)
            let shortSHA = String(sha.prefix(7))

            var commit: OpaquePointer?
            var subject = ""
            if git_commit_lookup(&commit, repo, &oid) == 0 {
                defer { git_commit_free(commit) }
                let msg = git_commit_message(commit).map { String(cString: $0) } ?? ""
                subject = msg.split(separator: "\n").first.map(String.init) ?? ""
            }

            return .wholeTree(
                targetSHA: sha, shortSHA: shortSHA,
                subject: subject, mode: mode)
        }
    }

    /// Per-pathspec reset (`git reset HEAD <paths>`): copy the listed
    /// entries from `target`'s tree into the index. Working tree
    /// untouched. Empty `paths` is a no-op (real git would refuse).
    @discardableResult
    public func reset(paths: [String], from target: String = "HEAD") async throws -> ResetOutcome {
        guard !paths.isEmpty else { return .paths([]) }
        return try await withRepository { repo in
            var object: OpaquePointer?
            try check(git_revparse_single(&object, repo, target))
            defer { git_object_free(object) }

            var copies: [UnsafeMutablePointer<CChar>?] = paths.map { strdup($0) }
            defer { for c in copies { free(c) } }
            try copies.withUnsafeMutableBufferPointer { buf in
                var arr = git_strarray(strings: buf.baseAddress, count: buf.count)
                try check(git_reset_default(repo, object, &arr))
            }
            return .paths(paths)
        }
    }
}
