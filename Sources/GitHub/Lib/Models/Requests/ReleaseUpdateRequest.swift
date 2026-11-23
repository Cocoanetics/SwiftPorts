import Foundation

/// Body for `PATCH /repos/{o}/{r}/releases/{id}`. Every field is
/// optional: `nil` omits the key, so the server keeps its current
/// value; explicit `false` / `""` are sent as-is.
public struct ReleaseUpdateRequest: Codable, Sendable {
    public var tagName: String?
    public var targetCommitish: String?
    public var name: String?
    public var body: String?
    public var draft: Bool?
    public var prerelease: Bool?
    public var makeLatest: String?  // "true" / "false" / "legacy"
    public var discussionCategoryName: String?

    public init(
        tagName: String? = nil,
        targetCommitish: String? = nil,
        name: String? = nil,
        body: String? = nil,
        draft: Bool? = nil,
        prerelease: Bool? = nil,
        makeLatest: String? = nil,
        discussionCategoryName: String? = nil
    ) {
        self.tagName = tagName
        self.targetCommitish = targetCommitish
        self.name = name
        self.body = body
        self.draft = draft
        self.prerelease = prerelease
        self.makeLatest = makeLatest
        self.discussionCategoryName = discussionCategoryName
    }
}
