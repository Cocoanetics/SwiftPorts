import Foundation

/// A GitLab merge request. Identified by `iid` (per-project).
///
/// Only the fields the CLI actually uses are decoded — extending the
/// model later as commands need more is cheap. The decoder is
/// snake_case-aware so adding a property is the only step.
public struct MergeRequest: Codable, Sendable, Identifiable {
    public let id: Int
    public let iid: Int
    public let projectId: Int
    public let title: String
    public let description: String?
    public let state: MergeRequestState
    public let draft: Bool?
    public let workInProgress: Bool?
    public let mergedAt: Date?
    public let closedAt: Date?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let targetBranch: String
    public let sourceBranch: String
    public let upvotes: Int?
    public let downvotes: Int?
    public let userNotesCount: Int?
    public let labels: [String]
    public let milestone: Milestone?
    public let author: User?
    public let assignee: User?
    public let assignees: [User]?
    public let reviewers: [User]?
    public let mergedBy: User?
    public let closedBy: User?
    public let sourceProjectId: Int?
    public let targetProjectId: Int?
    public let webUrl: URL
    public let mergeStatus: String?
    public let detailedMergeStatus: String?
    public let sha: String?
    public let mergeCommitSha: String?
    public let squashCommitSha: String?
    public let discussionLocked: Bool?
    public let shouldRemoveSourceBranch: Bool?
    public let forceRemoveSourceBranch: Bool?
    public let squash: Bool?
    public let hasConflicts: Bool?
    public let pipeline: Pipeline?
    public let headPipeline: Pipeline?
}
