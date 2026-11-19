import Foundation

/// The JSON returned by `git-lfs-authenticate` (`lfshttp.sshAuthResponse`).
public struct LFSSSHAuthResponse: Decodable, Sendable {
    public let href: String
    public let header: [String: String]
    public let expiresAt: Date?
    public private(set) var expiresIn: Int
    var createdAt = Date()

    private enum CodingKeys: String, CodingKey {
        case href, header
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        href = try values.decodeIfPresent(String.self, forKey: .href) ?? ""
        header = try values.decodeIfPresent([String: String].self, forKey: .header) ?? [:]
        expiresIn = try values.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 0
        if let text = try values.decodeIfPresent(String.self, forKey: .expiresAt) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: text)
            formatter.formatOptions = [.withInternetDateTime]
            guard let parsed = fractional ?? formatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .expiresAt, in: values, debugDescription: "invalid RFC 3339 time")
            }
            // Go's zero time means no expiration.
            expiresAt = parsed == formatter.date(from: "0001-01-01T00:00:00Z") ? nil : parsed
        } else {
            expiresAt = nil
        }
    }

    mutating func received(at date: Date, defaultTTL: Int) {
        createdAt = date
        if expiresIn == 0 && expiresAt == nil { expiresIn = max(0, defaultTTL) }
    }

    /// `tools.TimeAtOrIn` prefers the relative lifetime when both are present.
    var expiry: Date? {
        expiresIn == 0 ? expiresAt : createdAt.addingTimeInterval(TimeInterval(expiresIn))
    }

    func expired(at now: Date) -> Bool {
        guard let expiry else { return false }
        return expiry < now.addingTimeInterval(5)
    }
}
