import Foundation

enum ReleaseCreateError: Error, LocalizedError {
    case alreadyExists(tag: String)
    /// A 422 rejecting a non-semver tag (CI/CD catalog projects), with
    /// upstream's guidance appended.
    case semverTag(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let tag):
            return "release for tag \"\(tag)\" already exists and --no-update flag was specified"
        case .semverTag(let underlying):
            return underlying.localizedDescription + ". Use a MAJOR.MINOR.PATCH tag such as 1.0.0, v1.0.0, "
                + "or 1.0.0-alpha. Only a lowercase v prefix is allowed, and numeric identifiers must not "
                + "have leading zeros. See https://docs.gitlab.com/ci/components/#semantic-versioning"
        }
    }
}
