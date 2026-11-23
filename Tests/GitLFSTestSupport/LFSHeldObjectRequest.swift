import Foundation

/// A complete object request, observed on the server event loop after HTTP
/// request end and response parking, independently of response completion.
public struct LFSHeldObjectRequest: Sendable {
    public let method: String
    public let path: String
    public let requestBody: Data
    /// False if this request itself satisfied the overlap target and released
    /// the hold. True means its response was still parked at observation time.
    public let responseIsHeld: Bool
    public let receivedAt: ContinuousClock.Instant
}
