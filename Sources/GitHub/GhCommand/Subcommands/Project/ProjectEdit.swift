import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct ProjectEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a ProjectV2's metadata."
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")])
    var owner: String?

    @Flag(name: [.long, .customLong("org")])
    var asOrg: Bool = false

    @Option(name: [.short, .customLong("title")], help: "New title.")
    var title: String?

    @Option(name: .customLong("description"), help: "Short description.")
    var description: String?

    @Option(name: .customLong("readme"), help: "Long-form readme markdown.")
    var readme: String?

    @Flag(name: .customLong("public"), help: "Make the project public.")
    var makePublic: Bool = false

    @Flag(name: .customLong("private"), help: "Make the project private.")
    var makePrivate: Bool = false

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let ownerKind = ownerKind(owner: owner, asOrg: asOrg)
        let id = try await ProjectIDs.projectID(
            owner: ownerKind, number: number, gql: gql)

        var variables: [String: GraphQLValue] = ["id": .string(id)]
        if let title { variables["title"] = .string(title) }
        if let description { variables["shortDescription"] = .string(description) }
        if let readme { variables["readme"] = .string(readme) }
        if makePublic && makePrivate {
            throw ValidationError("Specify --public OR --private, not both.")
        }
        if makePublic { variables["public"] = .bool(true) }
        if makePrivate { variables["public"] = .bool(false) }

        let response: UpdateProjectResponse = try await gql.query(
            ProjectMutations.updateProject, variables: variables)
        let p = response.updateProjectV2.projectV2
        Stdio.print("\(ANSI.green("✓")) Edited #\(p.number): \(p.title)")
    }
}

struct ProjectClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a project (or reopen with --undo)."
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")])
    var owner: String?

    @Flag(name: [.long, .customLong("org")])
    var asOrg: Bool = false

    @Flag(name: .customLong("undo"), help: "Reopen the project.")
    var undo: Bool = false

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let ownerKind = ownerKind(owner: owner, asOrg: asOrg)
        let id = try await ProjectIDs.projectID(
            owner: ownerKind, number: number, gql: gql)

        let response: UpdateProjectResponse = try await gql.query(
            ProjectMutations.updateProject,
            variables: ["id": .string(id), "closed": .bool(!undo)])
        let p = response.updateProjectV2.projectV2
        Stdio.print("\(ANSI.green("✓")) \(undo ? "Reopened" : "Closed") #\(p.number)")
    }
}

struct ProjectDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a project."
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")])
    var owner: String?

    @Flag(name: [.long, .customLong("org")])
    var asOrg: Bool = false

    @Flag(name: [.short, .customLong("yes")], help: "Skip confirmation.")
    var skipPrompt: Bool = false

    func run() async throws {
        if !skipPrompt {
            Stdio.stderr.write(Data(
                "Permanently delete project #\(number)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else { throw ExitCode(1) }
        }
        let gql = try await CommandContext.graphQLClient()
        let ownerKind = ownerKind(owner: owner, asOrg: asOrg)
        let id = try await ProjectIDs.projectID(
            owner: ownerKind, number: number, gql: gql)

        let _: DeleteProjectResponse = try await gql.query(
            ProjectMutations.deleteProject,
            variables: ["id": .string(id)])
        Stdio.print("\(ANSI.green("✓")) Deleted project #\(number)")
    }
}

func ownerKind(owner: String?, asOrg: Bool) -> ProjectIDs.Owner {
    guard let owner else { return .viewer }
    return asOrg ? .organization(owner) : .user(owner)
}
