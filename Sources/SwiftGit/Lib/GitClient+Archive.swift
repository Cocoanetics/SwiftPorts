import Foundation
import ShellKit
import GitKit

// Sandbox-aware delegation onto the trait-gated `Repository.archive`
// (GitKit's `Archive` trait, enabled on our GitKit dependency — which is
// referenced by branch for exactly that reason; see Package.swift). The
// format enum (`GitArchiveFormat`) comes from GitKit too, re-exported
// through `@_exported import GitKit` so existing call sites keep compiling.
extension GitClient {

    /// Write `treeish`'s tree as an archive — `git archive`.
    ///
    /// Authorizes the output URL through the active sandbox, then delegates
    /// to ``GitKit/Repository/archive(treeish:format:to:prefix:)`` (libgit2
    /// tree-walk + libarchive writer; no `git` binary, no `Process` spawn).
    ///
    /// - Parameter prefix: prepended to every entry path. Trailing
    ///   slash is added if missing. Matches `git archive --prefix=`.
    public func archiveTree(
        treeish: String = "HEAD",
        format: GitArchiveFormat,
        to output: URL,
        prefix: String? = nil
    ) async throws {
        try await Shell.authorize(output)
        try await withRepository {
            try $0.archive(treeish: treeish, format: format, to: output, prefix: prefix)
        }
    }
}
