import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct SearchCode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "code",
        abstract: "Search for code in repositories.",
        discussion: """
        Requires authentication. The query syntax matches GitHub's
        web UI (e.g. 'foo language:swift repo:cli/cli').
        """
    )

    @Argument(parsing: .remaining, help: "Free-form query terms.")
    var query: [String] = []

    @Option(name: [.short, .customLong("limit")], help: "Maximum results.")
    var limit: Int = 30

    @Option(name: [.short, .long],
            help: "Filter to a specific repo (OWNER/NAME).")
    var repo: String?

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        guard !query.isEmpty else {
            throw ValidationError("Provide a search query.")
        }
        let client = try await CommandContext.apiClient()
        var qParts = query
        if let repo { qParts.append("repo:\(repo)") }
        let q = qParts.joined(separator: " ")
        let result: SearchResult<CodeSearchItem> = try await client.get(
            "search/code",
            query: [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "per_page", value: String(min(limit, 100))),
            ])
        let trimmed = Array(result.items.prefix(limit))

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: SearchFields.code)
            Stdio.print(try JSONFieldSelector.render(items: trimmed, fields: fields, fieldMap: SearchFields.code))
            return
        }
        if trimmed.isEmpty {
            Stdio.print("No code matches.")
            return
        }
        Stdio.print("Showing \(trimmed.count) of \(result.totalCount) results.")
        for item in trimmed {
            Stdio.print("\(item.repository.fullName)\t\(item.path)\t\(item.htmlUrl.absoluteString)")
        }
    }
}
