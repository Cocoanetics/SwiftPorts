import Foundation

/// Valid `content` values for GitHub's reaction-create endpoints on issues, issue
/// comments, commit comments, and pull-request review comments — all of which accept
/// the full set below.
///
/// The *release* reactions endpoint (`POST …/releases/{id}/reactions`) accepts only a
/// subset — it rejects `-1` and `confused` with a 422. Use ``releaseAllowed`` /
/// ``isValidForRelease`` to validate before targeting releases.
public enum ReactionContent: String, Codable, Sendable, CaseIterable {
    case plus1 = "+1"
    case minus1 = "-1"
    case laugh
    case confused
    case heart
    case hooray
    case rocket
    case eyes

    /// The subset GitHub accepts for release reactions: `+1`, `laugh`, `heart`,
    /// `hooray`, `rocket`, `eyes` (excludes `-1` and `confused`).
    public static let releaseAllowed: Set<ReactionContent> = [.plus1, .laugh, .heart, .hooray, .rocket, .eyes]

    /// Whether this content is accepted by the release reactions endpoint.
    public var isValidForRelease: Bool { Self.releaseAllowed.contains(self) }
}
