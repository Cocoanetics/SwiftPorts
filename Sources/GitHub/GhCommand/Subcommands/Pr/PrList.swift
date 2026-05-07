import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct PrList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List and filter pull requests."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("state")],
            help: "Filter by state.")
    var state: PrListState = .open

    @Option(name: [.short, .customLong("limit")],
            help: "Maximum number of PRs to fetch.")
    var limit: Int = 30

    @Option(name: .customLong("base"),
            help: "Filter by base branch.")
    var base: String?

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: PrFields.map)
            let gql = try await CommandContext.graphQLClient()
            var variables: [String: GraphQLValue] = [
                "owner": .string(target.owner),
                "name":  .string(target.name),
                "first": .int(min(limit, 100)),
                "states": graphqlStates(),
            ]
            if let base { variables["base"] = .string(base) }
            let response: PullRequestListResponse = try await gql.query(
                PullRequestQueries.list(), variables: variables)
            let prs = Array((response.repository?.pullRequests.nodes ?? []).prefix(limit))
            Stdio.print(try JSONFieldSelector.render(items: prs, fields: fields, fieldMap: PrFields.map))
            return
        }

        let client = try await CommandContext.apiClient()
        let perPage = min(limit, 100)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "state", value: state.rawValue),
            URLQueryItem(name: "per_page", value: String(perPage)),
        ]
        if let base { query.append(URLQueryItem(name: "base", value: base)) }

        let prs: [PullRequest] = try await client.get(
            "repos/\(target.slug)/pulls", query: query)
        let trimmed = Array(prs.prefix(limit))

        if trimmed.isEmpty {
            Stdio.print("No pull requests match.")
            return
        }
        for p in trimmed {
            Stdio.print("#\(p.number)\t\(p.state.rawValue)\t\(p.title)\t@\(p.user.login)\t\(p.head.ref)→\(p.base.ref)")
        }
    }

    /// Map our `state` enum to GraphQL's `[PullRequestState!]` filter.
    /// GraphQL variables accept enum literals as JSON strings.
    private func graphqlStates() -> GraphQLValue {
        switch state {
        case .open:   return .array([.string("OPEN")])
        case .closed: return .array([.string("CLOSED"), .string("MERGED")])
        case .all:    return .array([.string("OPEN"), .string("CLOSED"), .string("MERGED")])
        }
    }
}

enum PrListState: String, ExpressibleByArgument, Sendable {
    case open, closed, all
}
