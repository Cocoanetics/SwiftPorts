import Foundation

/// `state` of a ``PullReview``.
public enum PullReviewState: String, Codable, Sendable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case commented = "COMMENTED"
    case dismissed = "DISMISSED"
    case pending = "PENDING"
}
