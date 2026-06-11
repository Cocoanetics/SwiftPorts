import Foundation

/// A diff-anchored pull-request review comment. Returned by
/// `GET /repos/{o}/{r}/pulls/{n}/comments` (every review comment on
/// the PR) and `GET …/pulls/{n}/reviews/{id}/comments`.
///
/// Distinct from ``IssueComment`` (the timeline comments from
/// `…/issues/{n}/comments`): a review comment is pinned to a file
/// and line of the diff and threads via ``inReplyToId``.
public struct PullReviewComment: Codable, Sendable, Identifiable {
    public let id: Int
    public let nodeId: String
    public let url: URL
    /// The ``PullReview`` this comment belongs to. `nil` when the
    /// review was deleted.
    public let pullRequestReviewId: Int?
    /// The diff excerpt the comment is anchored to.
    public let diffHunk: String
    /// Repo-relative path of the commented file.
    public let path: String
    public let commitId: String
    public let originalCommitId: String
    /// Present when this comment replies to another review comment —
    /// the thread root's `id`.
    public let inReplyToId: Int?
    public let user: User
    public let body: String
    public let createdAt: Date
    public let updatedAt: Date
    public let htmlUrl: URL
    public let pullRequestUrl: URL
    public let authorAssociation: AuthorAssociation
    /// Line anchors against the current diff. `line` is `nil` when
    /// the comment is outdated (the diff moved on); `originalLine`
    /// keeps the anchor in the diff it was written against.
    /// `startLine`/`startSide` only appear on multi-line comments.
    public let line: Int?
    public let originalLine: Int?
    public let startLine: Int?
    public let originalStartLine: Int?
    /// `"LEFT"` / `"RIGHT"` — which side of the split diff.
    public let side: String?
    public let startSide: String?
    /// `"line"` or `"file"` — what the comment is attached to.
    public let subjectType: String?
    /// Legacy position fields (deprecated upstream in favour of the
    /// line anchors, still served).
    public let position: Int?
    public let originalPosition: Int?
    public let reactions: Reactions?
}
