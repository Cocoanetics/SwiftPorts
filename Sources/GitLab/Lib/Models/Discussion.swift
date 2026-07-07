import Foundation

/// A GitLab discussion groups one or more notes into a thread.
public struct Discussion: Codable, Sendable, Identifiable {
    public let id: String
    public let individualNote: Bool
    public let notes: [Note]
}
