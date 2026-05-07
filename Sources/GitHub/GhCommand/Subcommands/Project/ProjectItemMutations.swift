import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct ProjectItemAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "item-add",
        abstract: "Add an issue or PR to a ProjectV2.",
        discussion: """
        Pass --url to add an issue or pull request by its GitHub URL,
        or --draft to add a draft (title-only) item.
        """
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")])
    var owner: String?

    @Flag(name: [.long, .customLong("org")])
    var asOrg: Bool = false

    @Option(name: .customLong("url"),
            help: "GitHub URL of an issue or PR to add.")
    var url: String?

    @Option(name: .customLong("draft"),
            help: "Add a draft item with this title.")
    var draftTitle: String?

    @Option(name: .customLong("draft-body"),
            help: "Body for the draft item (only with --draft).")
    var draftBody: String?

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let ownerKind = ownerKind(owner: owner, asOrg: asOrg)
        let projectId = try await ProjectIDs.projectID(
            owner: ownerKind, number: number, gql: gql)

        if let url {
            guard let parsed = URL(string: url) else {
                throw ValidationError("--url is not a valid URL: \(url)")
            }
            let contentId = try await ProjectIDs.resourceID(url: parsed, gql: gql)
            let response: AddProjectItemByIdResponse = try await gql.query(
                ProjectMutations.addProjectItemById,
                variables: [
                    "projectId": .string(projectId),
                    "contentId": .string(contentId),
                ])
            Stdio.print("\(ANSI.green("✓")) Added item \(response.addProjectV2ItemById.item.id)")
        } else if let draftTitle {
            var variables: [String: GraphQLValue] = [
                "projectId": .string(projectId),
                "title": .string(draftTitle),
            ]
            if let draftBody { variables["body"] = .string(draftBody) }
            let response: AddProjectDraftIssueResponse = try await gql.query(
                ProjectMutations.addProjectDraftIssue, variables: variables)
            Stdio.print("\(ANSI.green("✓")) Added draft item \(response.addProjectV2DraftIssue.projectItem.id)")
        } else {
            throw ValidationError("Pass --url URL or --draft TITLE.")
        }
    }
}

struct ProjectItemArchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "item-archive",
        abstract: "Archive an item in a project (or unarchive with --undo)."
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")])
    var owner: String?

    @Flag(name: [.long, .customLong("org")])
    var asOrg: Bool = false

    @Option(name: .customLong("item-id"),
            help: "Item node ID (from `gh project item-list --json`).")
    var itemId: String

    @Flag(name: .customLong("undo"), help: "Unarchive instead.")
    var undo: Bool = false

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let ownerKind = ownerKind(owner: owner, asOrg: asOrg)
        let projectId = try await ProjectIDs.projectID(
            owner: ownerKind, number: number, gql: gql)

        if undo {
            let _: UnarchiveProjectItemResponse = try await gql.query(
                ProjectMutations.unarchiveProjectItem,
                variables: [
                    "projectId": .string(projectId),
                    "itemId": .string(itemId),
                ])
            Stdio.print("\(ANSI.green("✓")) Unarchived item \(itemId)")
        } else {
            let _: ArchiveProjectItemResponse = try await gql.query(
                ProjectMutations.archiveProjectItem,
                variables: [
                    "projectId": .string(projectId),
                    "itemId": .string(itemId),
                ])
            Stdio.print("\(ANSI.green("✓")) Archived item \(itemId)")
        }
    }
}

struct ProjectItemDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "item-delete",
        abstract: "Remove an item from a project."
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")])
    var owner: String?

    @Flag(name: [.long, .customLong("org")])
    var asOrg: Bool = false

    @Option(name: .customLong("item-id"), help: "Item node ID.")
    var itemId: String

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let ownerKind = ownerKind(owner: owner, asOrg: asOrg)
        let projectId = try await ProjectIDs.projectID(
            owner: ownerKind, number: number, gql: gql)

        let response: DeleteProjectItemResponse = try await gql.query(
            ProjectMutations.deleteProjectItem,
            variables: [
                "projectId": .string(projectId),
                "itemId": .string(itemId),
            ])
        Stdio.print("\(ANSI.green("✓")) Removed item \(response.deleteProjectV2Item.deletedItemId)")
    }
}
