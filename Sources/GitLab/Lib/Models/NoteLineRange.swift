import Foundation

/// Multi-line diff range attached to a diff note position.
public struct NoteLineRange: Codable, Sendable {
    public let start: NoteLinePosition?
    public let end: NoteLinePosition?
}
