import Foundation

/// Body for `PUT /projects/:id/releases/:tag_name`. Every field is
/// optional: `nil` omits the key, so the server keeps its current
/// value; explicit `""` and `[]` (which removes all milestone
/// associations) are sent as-is.
public struct ReleaseUpdateRequest: Codable, Sendable {
    public var name: String?
    public var description: String?
    public var milestones: [String]?
    public var releasedAt: Date?

    public init(
        name: String? = nil,
        description: String? = nil,
        milestones: [String]? = nil,
        releasedAt: Date? = nil
    ) {
        self.name = name
        self.description = description
        self.milestones = milestones
        self.releasedAt = releasedAt
    }
}
