import Foundation

/// A single GitHub reaction returned by `POST .../reactions`.
public struct Reaction: Codable, Sendable, Identifiable {
    public let id: Int
    public let user: User?
    public let content: String
    public let createdAt: Date
}
