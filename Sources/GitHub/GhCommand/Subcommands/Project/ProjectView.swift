import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct ProjectView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "View a ProjectV2 project."
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")],
            help: "User or organization login. Omit for your own.")
    var owner: String?

    @Flag(name: [.long, .customLong("org")],
          help: "Treat OWNER as an organization (otherwise tries user).")
    var asOrg: Bool = false

    @Option(name: .customLong("format"),
            help: "Output format: {json}.")
    var format: ProjectFormat?

    func run() async throws {
        let client = try await CommandContext.graphQLClient()
        let project: ProjectV2WithItemCount

        if let owner {
            if asOrg {
                let response: OrgProjectResponse = try await client.query(
                    ProjectQueries.orgProject,
                    variables: ["login": .string(owner), "number": .int(number)])
                guard let p = response.organization?.projectV2 else {
                    throw ValidationError(
                        "No project #\(number) on org '\(owner)'.")
                }
                project = p
            } else {
                let response: UserProjectResponse = try await client.query(
                    ProjectQueries.userProject,
                    variables: ["login": .string(owner), "number": .int(number)])
                guard let p = response.user?.projectV2 else {
                    throw ValidationError(
                        "No project #\(number) on user '\(owner)'.")
                }
                project = p
            }
        } else {
            let response: ViewerProjectResponse = try await client.query(
                ProjectQueries.viewerProject,
                variables: ["number": .int(number)])
            guard let p = response.viewer.projectV2 else {
                throw ValidationError("No project #\(number) for current user.")
            }
            project = p
        }

        if format == .json {
            Stdio.print(try ProjectJSONOutput.render(ProjectJSONOutput.project(project)))
            return
        }
        Stdio.print("\(ANSI.bold("Project #\(project.number)")): \(ANSI.bold(project.title))")
        let state = project.closed ? ANSI.magenta("closed") : ANSI.green("open")
        let visibility = project.public ? "public" : "private"
        Stdio.print("state: \(state)  visibility: \(visibility)  items: \(project.items.totalCount)")
        if let desc = project.shortDescription, !desc.isEmpty {
            Stdio.print("description: \(desc)")
        }
        Stdio.print("created: \(ISO8601DateFormatter().string(from: project.createdAt))")
        Stdio.print("url: \(project.url.absoluteString)")
        if let readme = project.readme, !readme.isEmpty {
            Stdio.print("\n--\n\(readme)")
        }
    }
}
