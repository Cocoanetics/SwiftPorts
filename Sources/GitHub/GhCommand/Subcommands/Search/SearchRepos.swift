import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct SearchRepos: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repos",
        abstract: "Search for repositories."
    )

    @Argument(parsing: .remaining,
              help: "Free-form query terms; passed to GitHub's repo search.")
    var query: [String] = []

    @Option(name: [.short, .customLong("limit")],
            help: "Maximum results to fetch.")
    var limit: Int = 30

    @Option(name: .long, help: "Sort: stars, forks, help-wanted-issues, updated, best-match (default).")
    var sort: String?

    @Option(name: .long, help: "Order: asc or desc.")
    var order: String = "desc"

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        guard !query.isEmpty else {
            throw ValidationError("Provide a search query, e.g. 'gh search repos swift cli'")
        }
        let client = try await CommandContext.apiClient()
        let q = query.joined(separator: " ")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "per_page", value: String(min(limit, 100))),
            URLQueryItem(name: "order", value: order),
        ]
        if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }

        let result: SearchResult<Repository> = try await client.get(
            "search/repositories", query: items)
        let trimmed = Array(result.items.prefix(limit))

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: SearchFields.repos)
            Stdio.print(try JSONFieldSelector.render(items: trimmed, fields: fields, fieldMap: SearchFields.repos))
            return
        }
        if trimmed.isEmpty {
            Stdio.print("No repositories found.")
            return
        }
        Stdio.print("Showing \(trimmed.count) of \(result.totalCount) results.")
        for r in trimmed {
            let lang = r.language ?? "—"
            let desc = r.description ?? ""
            Stdio.print("\(r.fullName)\t★\(r.stargazersCount)\t\(lang)\t\(desc)")
        }
    }
}
