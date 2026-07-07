import Foundation

/// One endpoint of a multi-line diff note range.
public struct NoteLinePosition: Codable, Sendable {
    public let lineCode: String?
    public let type: String?
    public let oldLine: Int?
    public let newLine: Int?
}
