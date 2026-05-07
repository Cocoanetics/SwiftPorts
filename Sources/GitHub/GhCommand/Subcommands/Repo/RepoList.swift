import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct RepoList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List repositories owned by a user or organization.",
        discussion: """
        Without OWNER, lists the authenticated user's own repos
        (requires a token).
        """
    )

    @Argument(help: "User or org login. Omit for your own repos.")
    var owner: String?

    @Option(name: [.short, .customLong("limit")],
            help: "Maximum repos to fetch.")
    var limit: Int = 30

    @Option(name: .customLong("visibility"),
            help: "Filter visibility: all, public, private. (Self only.)")
    var visibility: String?

    @Option(name: .customLong("type"),
            help: "Filter type: all, owner, member, public, private, forks, sources. (Self only.)")
    var type: String?

    @Option(name: .customLong("sort"),
            help: "Sort: created, updated, pushed, full_name (default).")
    var sort: String?

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: RepoFields.map)
            let gql = try await CommandContext.graphQLClient()
            let nodes: [GraphQLRepository]
            if let owner {
                // Try user first; if not found, fall back to organization.
                let userResponse: UserReposResponse = try await gql.query(
                    RepositoryViewQueries.userRepos,
                    variables: ["login": .string(owner), "first": .int(min(limit, 100))])
                if let userNodes = userResponse.user?.repositories.nodes {
                    nodes = userNodes
                } else {
                    let orgResponse: OrgReposResponse = try await gql.query(
                        RepositoryViewQueries.orgRepos,
                        variables: ["login": .string(owner), "first": .int(min(limit, 100))])
                    nodes = orgResponse.organization?.repositories.nodes ?? []
                }
            } else {
                let response: ViewerReposResponse = try await gql.query(
                    RepositoryViewQueries.viewerRepos,
                    variables: ["first": .int(min(limit, 100))])
                nodes = response.viewer.repositories.nodes
            }
            let trimmedNodes = Array(nodes.prefix(limit))
            Stdio.print(try JSONFieldSelector.render(items: trimmedNodes, fields: fields, fieldMap: RepoFields.map))
            return
        }

        let client = try await CommandContext.apiClient()
        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(min(limit, 100))),
        ]
        if let sort { query.append(URLQueryItem(name: "sort", value: sort)) }

        let path: String
        if let owner {
            path = "users/\(owner)/repos"
        } else {
            path = "user/repos"
            if let visibility { query.append(URLQueryItem(name: "visibility", value: visibility)) }
            if let type { query.append(URLQueryItem(name: "type", value: type)) }
        }

        let repos: [MinimalRepository] = try await client.get(path, query: query)
        let trimmed = Array(repos.prefix(limit))

        if trimmed.isEmpty {
            Stdio.print("No repositories.")
            return
        }
        for r in trimmed {
            let visibility = r.visibility?.rawValue ?? (r.private ? "private" : "public")
            let lang = r.language ?? "—"
            let desc = r.description ?? ""
            Stdio.print("\(r.fullName)\t\(visibility)\t\(lang)\t\(desc)")
        }
    }
}
