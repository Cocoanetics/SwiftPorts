import Foundation

/// Element returned by `GET /repos/{o}/{r}/commits/{ref}/statuses`
/// and embedded in the combined status response.
public struct CommitStatus: Codable, Sendable, Identifiable {
    public let id: Int
    public let nodeId: String
    public let state: String              // success | failure | pending | error
    public let description: String?
    public let targetUrl: URL?
    public let context: String
    public let createdAt: Date
    public let updatedAt: Date
    public let url: URL
    public let avatarUrl: URL?
    public let creator: User?
}

/// `GET /repos/{o}/{r}/commits/{ref}/status`.
public struct CombinedStatus: Codable, Sendable {
    public let state: String              // success | failure | pending | error
    public let statuses: [CommitStatus]
    public let sha: String
    public let totalCount: Int
    public let repository: MinimalRepository
    public let commitUrl: URL
    public let url: URL
}
