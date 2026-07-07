import Foundation

/// Diff anchor attached to GitLab review notes.
public struct NotePosition: Codable, Sendable {
    public let baseSha: String?
    public let startSha: String?
    public let headSha: String?
    public let oldPath: String?
    public let newPath: String?
    public let positionType: String?
    public let oldLine: Int?
    public let newLine: Int?
    public let lineRange: NoteLineRange?
}
