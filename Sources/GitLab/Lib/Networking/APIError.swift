import Foundation

/// Error surface for the GitLab `APIClient`.
public enum APIError: Error, Sendable {
    case transport(underlying: Error)
    case http(status: Int, message: String, url: URL)
    case unauthenticated(url: URL)
    case notFound(url: URL)
    case decoding(underlying: Error, url: URL)
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .transport(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .http(let status, let message, let url):
            let trimmed = message.isEmpty ? "" : ": \(message)"
            return "GitLab API \(status)\(trimmed) — \(url.absoluteString)"
        case .unauthenticated(let url):
            return "Unauthenticated. Set GITLAB_TOKEN or run `glab auth login`. (\(url.absoluteString))"
        case .notFound(let url):
            return "Not found: \(url.absoluteString)"
        case .decoding(let underlying, let url):
            return "Decode error from \(url.absoluteString): \(Self.describe(underlying))"
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else {
            return error.localizedDescription
        }

        switch error {
        case .keyNotFound(let key, let context):
            return "\(context.debugDescription) "
                + "(missing key \"\(key.stringValue)\"; "
                + "codingPath: \(format(context.codingPath)))"
        case .valueNotFound(let type, let context):
            return "\(context.debugDescription) "
                + "(missing \(type); codingPath: \(format(context.codingPath)))"
        case .typeMismatch(let type, let context):
            return "\(context.debugDescription) "
                + "(expected \(type); codingPath: \(format(context.codingPath)))"
        case .dataCorrupted(let context):
            return "\(context.debugDescription) "
                + "(codingPath: \(format(context.codingPath)))"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func format(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "<root>" }
        return codingPath.map(\.stringValue).joined(separator: ".")
    }
}
