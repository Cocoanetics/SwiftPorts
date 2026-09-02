import Foundation

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .http(let status, let message, let url):
            let msg = message.isEmpty ? "" : ": \(message)"
            return "HTTP \(status) from \(url.absoluteString)\(msg)"
        case .unauthenticated(let url):
            return "Authentication required for \(url.absoluteString). " +
                   "Set GH_TOKEN or GITHUB_TOKEN."
        case .rateLimited(let resetAt, let remaining, let retryAfter, let url):
            let left = remaining.map { " Remaining: \($0)." } ?? ""
            let when = resetAt.map { " Resets at \(ISO8601DateFormatter().string(from: $0))." } ?? ""
            let wait = retryAfter.map { " Retry after \(Int($0))s." } ?? ""
            return "Rate limit exceeded for \(url.absoluteString)." +
                   "\(left)\(when)\(wait) " +
                   "Authenticate with GH_TOKEN to raise the limit."
        case .notFound(let url):
            return "Not found: \(url.absoluteString)"
        case .transport(let err):
            return "Network error: \(err.localizedDescription)"
        case .decoding(let err, let url):
            return "Failed to parse response from \(url.absoluteString): \(err)"
        case .unexpectedContentType(let ct, let url):
            return "Unexpected content type \(ct ?? "nil") from \(url.absoluteString)"
        }
    }
}
