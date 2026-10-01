import Foundation

/// One stored version of a GitLab merge request's diff.
public struct MergeRequestDiffVersion: Codable, Sendable, Identifiable {
    public let id: Int
    public let headCommitSha: String?
    public let baseCommitSha: String?
    public let startCommitSha: String?
    public let createdAt: Date?
    public let mergeRequestId: Int?
    public let state: String?
    public let realSize: String?
    public let patchIdSha: String?
}
