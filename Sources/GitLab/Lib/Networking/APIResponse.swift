import Foundation
import HTTPTypes

/// Generic response wrapper for the GitLab `APIClient`. GitLab uses
/// header-based pagination — `X-Next-Page`, `X-Total-Pages`, etc.
public struct APIResponse: Sendable {
    public let status: Int
    public let body: Data
    public let url: URL
    public let nextPage: Int?
    public let totalPages: Int?
    public let total: Int?
    public let perPage: Int?
    public let contentType: String?
    public let headerFields: HTTPFields
    public let rateLimitRemaining: Int?
    public let rateLimitResetAt: Date?
    public let rateLimitResetTime: String?
    public let retryAfter: TimeInterval?

    public var etag: String? { headerFields[.eTag] }

    public init(
        status: Int,
        body: Data,
        url: URL,
        nextPage: Int?,
        totalPages: Int?,
        total: Int?,
        perPage: Int?,
        contentType: String?,
        rateLimitRemaining: Int? = nil,
        rateLimitResetAt: Date? = nil,
        rateLimitResetTime: String? = nil,
        retryAfter: TimeInterval? = nil,
        headerFields: HTTPFields = [:]
    ) {
        self.status = status
        self.body = body
        self.url = url
        self.nextPage = nextPage
        self.totalPages = totalPages
        self.total = total
        self.perPage = perPage
        self.contentType = contentType
        self.headerFields = headerFields
        self.rateLimitRemaining = rateLimitRemaining
        self.rateLimitResetAt = rateLimitResetAt
        self.rateLimitResetTime = rateLimitResetTime
        self.retryAfter = retryAfter
    }
}
