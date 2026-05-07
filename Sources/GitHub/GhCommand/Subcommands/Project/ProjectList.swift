import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ProjectList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List ProjectV2 projects."
    )

    @Option(name: [.customShort("o"), .customLong("owner")],
            help: "User or organization login. Omit for your own projects.")
    var owner: String?

    @Flag(name: [.long, .customLong("org")],
          help: "Treat OWNER as an organization (otherwise tries user).")
    var asOrg: Bool = false

    @Option(name: [.short, .customLong("limit")],
            help: "Maximum projects to fetch.")
    var limit: Int = 30

    @Option(name: .customLong("format"),
            help: "Output format: {json}.")
    var format: ProjectFormat?

    func run() async throws {
        let client = try await CommandContext.graphQLClient()
        let connection: ProjectV2Connection
        if let owner {
            if asOrg {
                let response: OrgProjectsResponse = try await client.query(
                    ProjectQueries.orgProjects,
                    variables: ["login": .string(owner),
                                "first": .int(min(limit, 100))])
                guard let org = response.organization else {
                    throw ValidationError("No organization named '\(owner)'.")
                }
                connection = org.projectsV2
            } else {
                let response: UserProjectsResponse = try await client.query(
                    ProjectQueries.userProjects,
                    variables: ["login": .string(owner),
                                "first": .int(min(limit, 100))])
                guard let user = response.user else {
                    throw ValidationError("No user named '\(owner)'. Pass --org if it's an organization.")
                }
                connection = user.projectsV2
            }
        } else {
            let response: ViewerProjectsResponse = try await client.query(
                ProjectQueries.viewerProjects,
                variables: ["first": .int(min(limit, 100))])
            connection = response.viewer.projectsV2
        }

        let trimmed = Array(connection.nodes.prefix(limit))
        if format == .json {
            let payload: [String: Any] = [
                "projects": trimmed.map { ProjectJSONOutput.project($0) },
                "totalCount": connection.totalCount ?? trimmed.count,
            ]
            Stdio.print(try ProjectJSONOutput.render(payload))
            return
        }
        if trimmed.isEmpty {
            Stdio.print("No projects.")
            return
        }
        Stdio.print("Showing \(trimmed.count) of \(connection.totalCount ?? trimmed.count) projects.")
        for p in trimmed {
            let visibility = p.public ? "public" : "private"
            let state = p.closed ? "closed" : "open"
            let title = p.title.isEmpty ? "(no title)" : p.title
            Stdio.print("#\(p.number)\t\(state)\t\(visibility)\t\(title)\t\(p.url.absoluteString)")
        }
    }
}
