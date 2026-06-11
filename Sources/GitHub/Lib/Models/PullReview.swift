import Foundation

/// A pull-request review submission. Returned by
/// `GET /repos/{o}/{r}/pulls/{n}/reviews`.
///
/// One review groups an approval / change-request / comment pass;
/// the diff-anchored comments attached to it are
/// ``PullReviewComment``s (their `pullRequestReviewId` points back
/// here).
public struct PullReview: Codable, Sendable, Identifiable {
    public let id: Int
    public let nodeId: String
    /// `nil` when the authoring account was deleted.
    public let user: User?
    /// Review summary text. Empty for plain approvals.
    public let body: String
    public let state: PullReviewState
    public let htmlUrl: URL
    public let pullRequestUrl: URL
    /// Absent on `PENDING` reviews — they haven't been submitted yet.
    public let submittedAt: Date?
    /// SHA the review is anchored to. Nullable per the API schema
    /// (e.g. after a force-push rewrote the branch).
    public let commitId: String?
    public let authorAssociation: AuthorAssociation
}
