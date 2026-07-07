import Foundation

/// GraphQL mutations for pull-request operations that have no REST
/// equivalent.
public enum PullRequestMutations {

    public static let resolveReviewThread = """
        mutation($threadId: ID!) {
          resolveReviewThread(input: {threadId: $threadId}) {
            thread { id isResolved }
          }
        }
        """

    public static let unresolveReviewThread = """
        mutation($threadId: ID!) {
          unresolveReviewThread(input: {threadId: $threadId}) {
            thread { id isResolved }
          }
        }
        """
}

public struct ResolveReviewThreadResponse: Codable, Sendable {
    public let resolveReviewThread: Inner
    public struct Inner: Codable, Sendable {
        public let thread: ReviewThreadResolutionState
    }
}

public struct UnresolveReviewThreadResponse: Codable, Sendable {
    public let unresolveReviewThread: Inner
    public struct Inner: Codable, Sendable {
        public let thread: ReviewThreadResolutionState
    }
}

public struct ReviewThreadResolutionState: Codable, Sendable {
    public let id: String
    public let isResolved: Bool
}
