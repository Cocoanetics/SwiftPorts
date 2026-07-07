import Foundation

/// A GitLab discussion groups one or more notes into a thread.
public struct Discussion: Codable, Sendable, Identifiable {
    public let id: String
    public let individualNote: Bool
    public let notes: [Note]

    /// Diff position for code-review discussions, carried by the
    /// first positioned note in GitLab's response payload.
    public var position: NotePosition? {
        notes.lazy.compactMap(\.position).first
    }
}
