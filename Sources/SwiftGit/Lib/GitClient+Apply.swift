import Foundation
import ForgeKit
import libgit2

/// Where to land an applied patch. Mirrors libgit2's
/// `git_apply_location_t` 1:1.
public enum ApplyLocation: Sendable {
    case workdir   // `git apply` (default)
    case index     // `git apply --cached`
    case both      // `git apply --index`

    fileprivate var raw: git_apply_location_t {
        switch self {
        case .workdir: return GIT_APPLY_LOCATION_WORKDIR
        case .index: return GIT_APPLY_LOCATION_INDEX
        case .both: return GIT_APPLY_LOCATION_BOTH
        }
    }
}

extension GitClient {

    /// Apply a unified-diff patch from `patchData`. Equivalent to
    /// `git apply` (with `--cached` / `--index` controlled by
    /// `location`).
    public func apply(patch patchData: Data, location: ApplyLocation = .workdir) async throws {
        try await withRepository { repo in
            // Parse the patch text into a git_diff.
            var diff: OpaquePointer?
            try patchData.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: CChar.self).baseAddress
                try check(git_diff_from_buffer(&diff, p, patchData.count))
            }
            defer { git_diff_free(diff) }

            try check(git_apply(repo, diff, location.raw, nil))
        }
    }
}
