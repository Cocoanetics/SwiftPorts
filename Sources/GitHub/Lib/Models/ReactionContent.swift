import Foundation

/// Valid `content` values for GitHub's reaction-create endpoints on issues, issue
/// comments, commit comments, and pull-request review comments — all of which accept
/// the full set below.
public enum ReactionContent: String, Codable, Sendable {
    case plus1 = "+1"
    case minus1 = "-1"
    case laugh
    case confused
    case heart
    case hooray
    case rocket
    case eyes
}
