import Foundation
import HTTPTypes

/// Raw response from ``APIClient``: the body, the complete header
/// fields, plus the handful of parsed headers the higher layers
/// care about.
public struct APIResponse: Sendable {
    public let status: Int
    public let body: Data
    public let nextPageURL: URL?
    public let rateLimitRemaining: Int?
    public let rateLimitResetAt: Date?
    public let contentType: String?
    public let oauthScopes: [String]?
    /// Every response header as received — needed by `gh api
    /// --include`, which prints the full set. Transfer headers that
    /// stopped describing `body` after transparent decompression are
    /// already scrubbed (see `APIClient.scrubbedHeaderFields`).
    public let headerFields: HTTPFields
    /// Negotiated protocol in Go's `resp.Proto` form (`HTTP/2.0`,
    /// `HTTP/1.1`). nil when the transport doesn't report it —
    /// corelibs-foundation never fires `URLSessionTaskMetrics`, and
    /// mocked sessions may not either.
    public let httpVersion: String?
    public let url: URL

    public init(
        status: Int,
        body: Data,
        nextPageURL: URL?,
        rateLimitRemaining: Int?,
        rateLimitResetAt: Date?,
        contentType: String?,
        oauthScopes: [String]? = nil,
        headerFields: HTTPFields = [:],
        httpVersion: String? = nil,
        url: URL
    ) {
        self.status = status
        self.body = body
        self.nextPageURL = nextPageURL
        self.rateLimitRemaining = rateLimitRemaining
        self.rateLimitResetAt = rateLimitResetAt
        self.contentType = contentType
        self.oauthScopes = oauthScopes
        self.headerFields = headerFields
        self.httpVersion = httpVersion
        self.url = url
    }
}
