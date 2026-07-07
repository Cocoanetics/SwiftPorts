import Foundation

/// Valid `content` values for GitHub's REST reaction-create endpoints.
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
