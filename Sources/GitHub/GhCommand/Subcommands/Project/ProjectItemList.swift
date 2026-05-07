import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ProjectItemList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "item-list",
        abstract: "List items in a ProjectV2 project."
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")],
            help: "User or organization login. Omit for your own.")
    var owner: String?

    @Flag(name: [.long, .customLong("org")],
          help: "Treat OWNER as an organization (otherwise tries user).")
    var asOrg: Bool = false

    @Option(name: [.short, .customLong("limit")],
            help: "Maximum items to fetch.")
    var limit: Int = 30

    @Option(name: .customLong("format"),
            help: "Output format: {json}.")
    var format: ProjectFormat?

    func run() async throws {
        let client = try await CommandContext.graphQLClient()
        let connection: ProjectV2ItemConnection

        if let owner {
            if asOrg {
                let response: OrgProjectItemsResponse = try await client.query(
                    ProjectQueries.orgProjectItems,
                    variables: ["login": .string(owner),
                                "number": .int(number),
                                "first": .int(min(limit, 100))])
                guard let p = response.organization?.projectV2 else {
                    throw ValidationError(
                        "No project #\(number) on org '\(owner)'.")
                }
                connection = p.items
            } else {
                let response: UserProjectItemsResponse = try await client.query(
                    ProjectQueries.userProjectItems,
                    variables: ["login": .string(owner),
                                "number": .int(number),
                                "first": .int(min(limit, 100))])
                guard let p = response.user?.projectV2 else {
                    throw ValidationError(
                        "No project #\(number) on user '\(owner)'.")
                }
                connection = p.items
            }
        } else {
            let response: ViewerProjectItemsResponse = try await client.query(
                ProjectQueries.viewerProjectItems,
                variables: ["number": .int(number),
                            "first": .int(min(limit, 100))])
            guard let p = response.viewer.projectV2 else {
                throw ValidationError("No project #\(number) for current user.")
            }
            connection = p.items
        }

        let trimmed = Array(connection.nodes.prefix(limit))
        if format == .json {
            let payload: [String: Any] = [
                "items": trimmed.map { itemDict($0) },
                "totalCount": connection.totalCount,
            ]
            Stdio.print(try ProjectJSONOutput.render(payload))
            return
        }
        if trimmed.isEmpty {
            Stdio.print("No items.")
            return
        }
        Stdio.print("Showing \(trimmed.count) of \(connection.totalCount) items.")
        for item in trimmed {
            let summary = describe(item)
            Stdio.print("\(item.type.rawValue)\t\(summary)")
        }
    }

    private func describe(_ item: ProjectV2Item) -> String {
        switch item.content {
        case .issue(let i): return "#\(i.number) \(i.state) \(i.title)"
        case .pullRequest(let p): return "#\(p.number) \(p.state) \(p.title)"
        case .draftIssue(let d): return "(draft) \(d.title)"
        case .unknown, nil: return "(redacted or unknown)"
        }
    }

    /// Upstream `gh project item-list --format json` shape per item:
    /// `{"id","title","content":{"type","number","title","state","url"}}`.
    /// Draft issues lack number/state and use type "DraftIssue".
    private func itemDict(_ item: ProjectV2Item) -> [String: Any] {
        var content: [String: Any] = [:]
        switch item.content {
        case .issue(let i):
            content = [
                "type": "Issue",
                "number": i.number,
                "title": i.title,
                "state": i.state,
                "url": i.url.absoluteString,
            ]
        case .pullRequest(let p):
            content = [
                "type": "PullRequest",
                "number": p.number,
                "title": p.title,
                "state": p.state,
                "url": p.url.absoluteString,
            ]
        case .draftIssue(let d):
            content = [
                "type": "DraftIssue",
                "title": d.title,
                "body": d.body ?? "",
            ]
        case .unknown, .none:
            content = ["type": "Redacted"]
        }
        let title: String = {
            switch item.content {
            case .issue(let i): return i.title
            case .pullRequest(let p): return p.title
            case .draftIssue(let d): return d.title
            case .unknown, .none: return ""
            }
        }()
        return [
            "id": item.id,
            "title": title,
            "content": content,
        ]
    }
}
