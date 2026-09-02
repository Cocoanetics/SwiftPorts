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
        case .rateLimited(let resetAt, let remaining, let retryAfter, let message, let url):
            // GitHub's own text separates the two limits ("You have
            // exceeded a secondary rate limit…" vs "API rate limit
            // exceeded…") more precisely than we can synthesise.
            var text = message.isEmpty
                ? "Rate limit exceeded for \(url.absoluteString)."
                : "\(message) (\(url.absoluteString))"
            if let remaining { text += " Remaining: \(remaining)." }
            if let resetAt {
                text += " Resets at \(ISO8601DateFormatter().string(from: resetAt))."
            }
            if let retryAfter {
                // A secondary limit throttles the request rate, not the
                // hourly budget — authenticating doesn't raise it, so
                // the GH_TOKEN advice would send the caller the wrong
                // way. Honouring the wait is the fix.
                text += " Retry after \(retryAfter)s."
            } else {
                text += " Authenticate with GH_TOKEN to raise the limit."
            }
            return text
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
