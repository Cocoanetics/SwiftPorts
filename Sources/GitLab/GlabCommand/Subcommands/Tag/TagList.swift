import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct TagList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List repository tags."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("limit")])
    var limit: Int = 30

    @Option(name: [.customShort("s"), .long],
            help: "Search filter (substring of tag name).")
    var search: String?

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(min(limit, 100))),
        ]
        if let search { query.append(URLQueryItem(name: "search", value: search)) }
        let tags: [Tag] = try await client.get(
            "projects/\(target.encodedPath)/repository/tags",
            query: query)
        if tags.isEmpty { Stdio.print("No tags."); return }
        for tag in tags.prefix(limit) {
            let commit = tag.commit?.shortId ?? tag.commit?.id.prefix(7).description ?? ""
            let title = tag.message?.split(separator: "\n").first.map(String.init) ?? ""
            Stdio.print("\(tag.name)\t\(commit)\t\(title)")
        }
    }
}
