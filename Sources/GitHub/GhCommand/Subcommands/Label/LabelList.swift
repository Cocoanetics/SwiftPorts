import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct LabelList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the labels in a repository."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("limit")], help: "Maximum labels to fetch.")
    var limit: Int = 100

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)

        // GraphQL path covers `--json` (gh's id is the GraphQL node ID,
        // and it surfaces createdAt/updatedAt that REST omits).
        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: LabelFields.list)
            let gql = try await CommandContext.graphQLClient()
            let response: RepositoryLabelsResponse = try await gql.query(
                RepositoryQueries.repositoryLabels,
                variables: [
                    "owner": .string(target.owner),
                    "name":  .string(target.name),
                    "first": .int(min(limit, 100)),
                ])
            let nodes = Array((response.repository?.labels.nodes ?? []).prefix(limit))
            Stdio.print(try JSONFieldSelector.render(items: nodes, fields: fields, fieldMap: LabelFields.list))
            return
        }

        let client = try await CommandContext.apiClient()
        let labels: [Label] = try await client.get(
            "repos/\(target.slug)/labels",
            query: [URLQueryItem(name: "per_page", value: String(min(limit, 100)))])
        let trimmed = Array(labels.prefix(limit))

        if trimmed.isEmpty {
            Stdio.print("No labels in \(target.slug).")
            return
        }
        for l in trimmed {
            let desc = l.description ?? ""
            Stdio.print("\(l.name)\t#\(l.color)\t\(desc)")
        }
    }
}

enum LabelFields {
    /// Fields exposed by `gh label list --json`.
    static let list: [String: @Sendable (GraphQLLabel) -> Any?] = [
        "color":       { $0.color },
        "createdAt":   { $0.createdAt.map(JSONFieldSelector.iso8601) },
        "description": { $0.description ?? "" },
        "id":          { $0.id },
        "isDefault":   { $0.isDefault },
        "name":        { $0.name },
        "updatedAt":   { $0.updatedAt.map(JSONFieldSelector.iso8601) },
        "url":         { $0.url.absoluteString },
    ]
}
