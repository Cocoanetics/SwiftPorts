import Foundation

/// Failures `gh release edit` reports with upstream's wording.
enum ReleaseEditError: Error, LocalizedError, Equatable {
    /// Upstream `shared.ErrReleaseNotFound`.
    case releaseNotFound
    case tagNotFound(tag: String, repo: String)

    var errorDescription: String? {
        switch self {
        case .releaseNotFound:
            return "release not found"
        case .tagNotFound(let tag, let repo):
            return "tag \(tag) doesn't exist in the repo \(repo), aborting due to --verify-tag flag"
        }
    }
}
