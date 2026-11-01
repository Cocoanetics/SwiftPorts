import Foundation

/// A pull request. Returned by `GET /repos/{o}/{r}/pulls` and detail
/// endpoints. Has a superset of ``Issue``'s fields.
public struct PullRequest: Codable, Sendable, Identifiable {
    public let id: Int
    public let nodeId: String
    public let number: Int
    public let title: String
    public let body: String?
    public let state: PullRequestState
    public let locked: Bool
    public let user: User
    public let assignees: [User]
    public let requestedReviewers: [User]?
    public let labels: [Label]
    public let milestone: Milestone?
    public let head: PullRequestRef
    public let base: PullRequestRef
    public let merged: Bool?
    public let mergeable: Bool?
    public let mergeableState: String?
    public let mergedBy: User?
    public let autoMerge: PullRequestAutoMerge?
    public let comments: Int?
    public let reviewComments: Int?
    public let commits: Int?
    public let additions: Int?
    public let deletions: Int?
    public let changedFiles: Int?
    public let draft: Bool?
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let mergedAt: Date?
    public let mergeCommitSha: String?
    public let htmlUrl: URL
    public let diffUrl: URL
    public let patchUrl: URL
    public let url: URL
    public let authorAssociation: AuthorAssociation
}
