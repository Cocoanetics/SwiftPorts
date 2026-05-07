import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct IssueList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List and filter issues."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("state")],
            help: "Filter by state.")
    var state: IssueListState = .open

    @Option(name: [.customShort("L"), .customLong("limit")],
            help: "Maximum number of issues to fetch.")
    var limit: Int = 30

    @Option(name: [.short, .customLong("label")],
            parsing: .singleValue,
            help: "Filter by label; repeatable.")
    var labels: [String] = []

    @Option(name: .customLong("author"),
            help: "Filter by author login.")
    var author: String?

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: IssueFields.map)
            let gql = try await CommandContext.graphQLClient()
            var variables: [String: GraphQLValue] = [
                "owner": .string(target.owner),
                "name":  .string(target.name),
                "first": .int(min(limit, 100)),
                "states": graphqlStates(),
            ]
            if !labels.isEmpty {
                variables["labels"] = .array(labels.map(GraphQLValue.string))
            }
            let response: IssueListResponse = try await gql.query(
                IssueQueries.list(), variables: variables)
            let issues = Array((response.repository?.issues.nodes ?? []).prefix(limit))
            Stdio.print(try JSONFieldSelector.render(items: issues, fields: fields, fieldMap: IssueFields.map))
            return
        }

        let client = try await CommandContext.apiClient()
        let perPage = min(limit, 100)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        if !labels.isEmpty {
            query.append(URLQueryItem(name: "labels", value: labels.joined(separator: ",")))
        }
        if let author { query.append(URLQueryItem(name: "creator", value: author)) }

        let issues: [Issue] = try await client.get(
            "repos/\(target.slug)/issues", query: query)
        // The /issues endpoint returns PRs too — drop them.
        let onlyIssues = issues.filter { $0.pullRequest == nil }
        let trimmed = Array(onlyIssues.prefix(limit))

        if trimmed.isEmpty {
            Stdio.print("No issues match.")
            return
        }
        for i in trimmed {
            Stdio.print("#\(i.number)\t\(i.state.rawValue)\t\(i.title)\t@\(i.user.login)")
        }
    }

    private func graphqlStates() -> GraphQLValue {
        switch state {
        case .open:   return .array([.string("OPEN")])
        case .closed: return .array([.string("CLOSED")])
        case .all:    return .array([.string("OPEN"), .string("CLOSED")])
        }
    }
}

enum IssueListState: String, ExpressibleByArgument, Sendable {
    case open, closed, all
}
