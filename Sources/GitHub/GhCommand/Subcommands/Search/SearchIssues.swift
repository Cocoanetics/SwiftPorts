import ArgumentParser
import Sandbox
import Foundation
import GitHub

/// Shared implementation for `gh search issues` and `gh search prs`.
/// Both hit `/search/issues`; `prs` adds `is:pr`, `issues` adds `is:issue`.
struct SearchIssuesBase {
    static func run(
        kind: String,
        rawQuery: [String],
        state: String?,
        author: String?,
        repo: String?,
        limit: Int,
        json: String?
    ) async throws {
        guard !rawQuery.isEmpty else {
            throw ValidationError("Provide a search query.")
        }
        let client = try await CommandContext.apiClient()
        var qParts = rawQuery + ["is:\(kind)"]
        if let state { qParts.append("state:\(state)") }
        if let author { qParts.append("author:\(author)") }
        if let repo { qParts.append("repo:\(repo)") }

        let result: SearchResult<Issue> = try await client.get(
            "search/issues",
            query: [
                URLQueryItem(name: "q", value: qParts.joined(separator: " ")),
                URLQueryItem(name: "per_page", value: String(min(limit, 100))),
            ])
        let trimmed = Array(result.items.prefix(limit))

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: SearchFields.issues)
            Stdio.print(try JSONFieldSelector.render(items: trimmed, fields: fields, fieldMap: SearchFields.issues))
            return
        }
        if trimmed.isEmpty {
            Stdio.print("No \(kind)s match.")
            return
        }
        Stdio.print("Showing \(trimmed.count) of \(result.totalCount) results.")
        for item in trimmed {
            let repoSlug = item.repositoryUrl.lastTwoPathComponents
            Stdio.print("\(repoSlug)#\(item.number)\t\(item.state.rawValue)\t\(item.title)\t@\(item.user.login)")
        }
    }
}

struct SearchIssuesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "issues",
        abstract: "Search for issues."
    )

    @Argument(parsing: .remaining, help: "Free-form query terms.")
    var query: [String] = []
    @Option(name: [.short, .customLong("limit")]) var limit: Int = 30
    @Option(name: .long, help: "Filter by state (open / closed).") var state: String?
    @Option(name: .long, help: "Filter by author.") var author: String?
    @Option(name: [.short, .long], help: "Filter to a specific repo (OWNER/NAME).") var repo: String?
    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        try await SearchIssuesBase.run(
            kind: "issue", rawQuery: query, state: state,
            author: author, repo: repo, limit: limit, json: json)
    }
}

struct SearchPrsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prs",
        abstract: "Search for pull requests."
    )

    @Argument(parsing: .remaining, help: "Free-form query terms.")
    var query: [String] = []
    @Option(name: [.short, .customLong("limit")]) var limit: Int = 30
    @Option(name: .long, help: "Filter by state (open / closed / merged).") var state: String?
    @Option(name: .long, help: "Filter by author.") var author: String?
    @Option(name: [.short, .long], help: "Filter to a specific repo (OWNER/NAME).") var repo: String?
    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        try await SearchIssuesBase.run(
            kind: "pr", rawQuery: query, state: state,
            author: author, repo: repo, limit: limit, json: json)
    }
}

private extension URL {
    /// `https://api.github.com/repos/cli/cli` → `cli/cli`. Used to
    /// produce a friendly slug from `repository_url` since search
    /// items don't carry a full `Repository`.
    var lastTwoPathComponents: String {
        let parts = pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return path }
        return parts.suffix(2).joined(separator: "/")
    }
}
