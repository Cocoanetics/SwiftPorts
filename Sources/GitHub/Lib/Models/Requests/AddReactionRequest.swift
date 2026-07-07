import Foundation

/// Body for GitHub's REST reaction-create endpoints:
/// `POST /repos/{o}/{r}/pulls/comments/{id}/reactions`,
/// `POST /repos/{o}/{r}/issues/comments/{id}/reactions`, and
/// `POST /repos/{o}/{r}/issues/{number}/reactions`.
public struct AddReactionRequest: Codable, Sendable {
    public var content: ReactionContent

    public init(content: ReactionContent) {
        self.content = content
    }
}
