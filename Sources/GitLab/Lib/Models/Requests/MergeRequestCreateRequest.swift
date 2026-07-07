import Foundation

/// Body for `POST /projects/:id/merge_requests`.
public struct MergeRequestCreateRequest: Codable, Sendable {
    public var title: String
    public var description: String?
    public var sourceBranch: String
    public var targetBranch: String?
    public var labels: String?
    public var assigneeIds: [Int]?
    public var reviewerIds: [Int]?
    public var milestoneId: Int?
    public var removeSourceBranch: Bool?
    public var squash: Bool?

    public init(
        title: String,
        sourceBranch: String,
        targetBranch: String? = nil,
        description: String? = nil,
        labels: String? = nil,
        assigneeIds: [Int]? = nil,
        reviewerIds: [Int]? = nil,
        milestoneId: Int? = nil,
        removeSourceBranch: Bool? = nil,
        squash: Bool? = nil
    ) {
        self.title = title
        self.description = description
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.labels = labels
        self.assigneeIds = assigneeIds
        self.reviewerIds = reviewerIds
        self.milestoneId = milestoneId
        self.removeSourceBranch = removeSourceBranch
        self.squash = squash
    }
}
