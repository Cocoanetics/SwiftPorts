import Foundation

/// Errors thrown by ``APIClient``.
public enum APIError: Error, Sendable {
    /// Non-2xx HTTP response. `message` is the server's error message
    /// when parseable (`{"message": "..."}`), otherwise empty.
    case http(status: Int, message: String, url: URL)
    /// 401 / 403 with no token configured.
    case unauthenticated(url: URL)
    /// 403 or 429 identifying a rate limit — primary
    /// (`X-RateLimit-Remaining: 0`) or secondary (`Retry-After`).
    /// `resetAt` is the wall-clock time when the primary limit
    /// refreshes; `retryAfter` is the whole seconds GitHub asked the
    /// caller to wait, present on secondary limits. Both are nil when
    /// the response carried neither header. `message` is the server's
    /// error text, as on ``http(status:message:url:)`` — GitHub
    /// distinguishes the two limits there ("You have exceeded a
    /// secondary rate limit…" vs "API rate limit exceeded…") better
    /// than the status and headers alone do.
    case rateLimited(
        resetAt: Date?,
        remaining: Int?,
        retryAfter: Int?,
        message: String,
        url: URL)
    /// 404 — disambiguated from generic HTTP for command-level
    /// exit-code mapping.
    case notFound(url: URL)
    /// `URLSession` error (DNS failure, timeout, TLS, etc.).
    case transport(underlying: Error)
    /// JSON parse failure on a 2xx body.
    case decoding(underlying: Error, url: URL)
    /// Server returned 2xx but body wasn't the expected media type.
    case unexpectedContentType(String?, url: URL)
}
