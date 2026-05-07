import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct IssueList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List project issues.",
        aliases: ["ls"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("a"), .long],
            help: "Filter by assignee username.")
    var assignee: String?

    @Option(name: .long,
            help: "Filter by author username.")
    var author: String?

    @Option(name: [.customShort("l"), .customLong("label")],
            parsing: .singleValue,
            help: "Filter by label; repeatable.")
    var labels: [String] = []

    @Option(name: [.customShort("m"), .long],
            help: "Filter by milestone title.")
    var milestone: String?

    @Option(name: .long,
            help: "Search the title and description.")
    var search: String?

    @Flag(name: [.customShort("A"), .long],
          help: "Get all issues regardless of state.")
    var all: Bool = false

    @Flag(name: [.customShort("c"), .long],
          help: "Get only closed issues.")
    var closed: Bool = false

    @Flag(name: [.customShort("C"), .long],
          help: "Filter by confidential issues.")
    var confidential: Bool = false

    @Option(name: [.customShort("P"), .customLong("per-page")],
            help: "Items per page.")
    var perPage: Int = 30

    @Option(name: [.customShort("p"), .long],
            help: "Page number.")
    var page: Int = 1

    @Flag(name: .long, help: "Print as JSON array.")
    var json: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        var query: [URLQueryItem] = []
        let state: String = all ? "all" : (closed ? "closed" : "opened")
        query.append(URLQueryItem(name: "state", value: state))
        query.append(URLQueryItem(name: "per_page", value: String(perPage)))
        query.append(URLQueryItem(name: "page", value: String(page)))
        if let assignee {
            query.append(URLQueryItem(name: "assignee_username", value: assignee))
        }
        if let author {
            query.append(URLQueryItem(name: "author_username", value: author))
        }
        if !labels.isEmpty {
            query.append(URLQueryItem(name: "labels", value: labels.joined(separator: ",")))
        }
        if let milestone {
            query.append(URLQueryItem(name: "milestone", value: milestone))
        }
        if let search {
            query.append(URLQueryItem(name: "search", value: search))
        }
        if confidential {
            query.append(URLQueryItem(name: "confidential", value: "true"))
        }

        let path = "projects/\(target.encodedPath)/issues"
        let issues: [Issue] = try await client.get(path, query: query)

        if json {
            Stdio.print(try CodableOutput.prettyJSON(issues))
            return
        }
        if issues.isEmpty {
            Stdio.print("No issues match.")
            return
        }
        for issue in issues {
            let stateColor = issue.state == .opened
                ? ANSI.green("#\(issue.iid)")
                : ANSI.red("#\(issue.iid)")
            let labelChunk = issue.labels.isEmpty
                ? ""
                : "  " + ANSI.cyan("(\(issue.labels.joined(separator: ", ")))")
            Stdio.print("\(stateColor)\t\(issue.title)\(labelChunk)")
        }
    }
}
