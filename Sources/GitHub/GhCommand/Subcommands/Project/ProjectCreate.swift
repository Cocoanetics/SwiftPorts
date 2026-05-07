import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct ProjectCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new ProjectV2 project."
    )

    @Option(name: [.short, .customLong("title")], help: "Project title.")
    var title: String

    @Option(name: [.customShort("o"), .customLong("owner")],
            help: "User or org login. Omit to create on your own account.")
    var owner: String?

    @Flag(name: [.long, .customLong("org")],
          help: "Treat OWNER as an organization.")
    var asOrg: Bool = false

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let ownerKind: ProjectIDs.Owner = {
            guard let owner else { return .viewer }
            return asOrg ? .organization(owner) : .user(owner)
        }()
        let ownerNodeId = try await ProjectIDs.ownerID(ownerKind, gql: gql)

        let response: CreateProjectResponse = try await gql.query(
            ProjectMutations.createProject,
            variables: [
                "ownerId": .string(ownerNodeId),
                "title": .string(title),
            ])
        let p = response.createProjectV2.projectV2
        Stdio.print("\(ANSI.green("✓")) Created project #\(p.number): \(p.title)")
        Stdio.print(p.url.absoluteString)
    }
}
