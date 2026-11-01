import Foundation

/// The REST `auto_merge` object. A nil ``PullRequest/autoMerge`` means
/// auto-merge is not enabled; REST merge methods use lowercase values.
public struct PullRequestAutoMerge: Codable, Sendable {
    public let enabledBy: User
    public let mergeMethod: PullRequestMergeRequest.MergeMethod
    public let commitTitle: String?
    public let commitMessage: String?
}
