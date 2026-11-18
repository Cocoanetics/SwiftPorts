import Foundation
import GitLab

/// Resolves an issue argument that may be a number, `#123`, or a full
/// GitLab issue URL. Returns the IID plus an optional repository
/// reference parsed from the URL (if URL form was used).
enum IssueArgument {
    // Mirrors glab v1.130's internal/cmdutils/url_parser.go issueURLPathRE.
    // Only issues accept incident/; both URL kinds accept trailing path segments.
    private static let issueURLPathRE = try? NSRegularExpression(
        pattern: #"^(/(?:[^-][^/]+/){2,})+(?:-/)?(?:issues/(?:incident/)?|work_items/)([0-9]+)(?:/.*)?$"#)

    struct Parsed {
        let iid: Int
        let repoFromURL: RepositoryReference?
    }

    static func parse(_ raw: String) throws -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        // URL form: https://gitlab.com/group/sub/repo/-/{issues,work_items}/123
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            return try parseURL(url, raw: raw)
        }

        // Numeric form (with or without leading `#`).
        let stripped = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard let iid = Int(stripped), iid > 0 else {
            throw IssueArgumentError.malformed(raw)
        }
        return Parsed(iid: iid, repoFromURL: nil)
    }

    private static func parseURL(_ url: URL, raw: String) throws -> Parsed {
        guard let host = url.host, !host.isEmpty else {
            throw IssueArgumentError.malformed(raw)
        }
        let path = url.path
        guard let match = issueURLPathRE?.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let repoRange = Range(match.range(at: 1), in: path),
              let iidRange = Range(match.range(at: 2), in: path),
              let iid = Int(path[iidRange]), iid > 0 else {
            throw IssueArgumentError.malformed(raw)
        }
        let repoSegments = path[repoRange].split(separator: "/").map(String.init)
        let ref = RepositoryReference(host: host, pathSegments: repoSegments)
        return Parsed(iid: iid, repoFromURL: ref)
    }
}

enum IssueArgumentError: Error, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let s):
            return "invalid issue format: \(String(reflecting: s))"
        }
    }
}
