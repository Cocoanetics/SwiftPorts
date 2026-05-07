import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct ProjectFieldCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "field-create",
        abstract: "Create a custom field on a ProjectV2.",
        discussion: """
        Supported data types: TEXT, NUMBER, DATE, SINGLE_SELECT.
        SINGLE_SELECT requires --option SLUG=Color name; repeat per option.
        Color is optional and one of: GRAY, BLUE, GREEN, YELLOW, ORANGE, RED, PINK, PURPLE.
        Iteration fields aren't supported here — they're configured via the web UI.
        """
    )

    @Argument(help: "Project number.") var number: Int
    @Option(name: [.customShort("o"), .customLong("owner")]) var owner: String?
    @Flag(name: [.long, .customLong("org")]) var asOrg: Bool = false

    @Option(name: [.short, .customLong("name")], help: "Field name.")
    var name: String

    @Option(name: .customLong("data-type"),
            help: "TEXT | NUMBER | DATE | SINGLE_SELECT.")
    var dataType: String

    @Option(name: .customLong("option"),
            parsing: .singleValue,
            help: "Single-select option as 'NAME' or 'NAME=COLOR'; repeatable.")
    var options: [String] = []

    func run() async throws {
        let normalizedType = dataType.uppercased()
        guard ["TEXT", "NUMBER", "DATE", "SINGLE_SELECT"].contains(normalizedType) else {
            throw ValidationError("--data-type must be TEXT, NUMBER, DATE, or SINGLE_SELECT.")
        }

        let gql = try await CommandContext.graphQLClient()
        let projectId = try await ProjectIDs.projectID(
            owner: ownerKind(owner: owner, asOrg: asOrg),
            number: number, gql: gql)

        var variables: [String: GraphQLValue] = [
            "projectId": .string(projectId),
            "name": .string(name),
            "dataType": .string(normalizedType),
        ]

        if normalizedType == "SINGLE_SELECT" {
            guard !options.isEmpty else {
                throw ValidationError("SINGLE_SELECT fields need at least one --option.")
            }
            let parsed: [GraphQLValue] = options.map { raw in
                let parts = raw.split(separator: "=", maxSplits: 1)
                let optionName = String(parts[0])
                let color = parts.count > 1 ? String(parts[1]) : "GRAY"
                return .object([
                    "name": .string(optionName),
                    "color": .string(color.uppercased()),
                    "description": .string(""),
                ])
            }
            variables["options"] = .array(parsed)
        }

        let response: CreateFieldResponse = try await gql.query(
            ProjectMutations.createField, variables: variables)
        let f = response.createProjectV2Field.projectV2Field
        Stdio.print("\(ANSI.green("✓")) Created field \(f.name) (\(f.id))")
    }
}

struct ProjectFieldDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "field-delete",
        abstract: "Delete a custom field from a ProjectV2."
    )
    @Option(name: .customLong("field-id"), help: "Field node ID.")
    var fieldId: String
    @Flag(name: [.short, .customLong("yes")]) var skipPrompt: Bool = false

    func run() async throws {
        if !skipPrompt {
            Stdio.stderr.write(Data(
                "Delete field \(fieldId)? This destroys all values stored in it. [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else { throw ExitCode(1) }
        }
        let gql = try await CommandContext.graphQLClient()
        let response: DeleteFieldResponse = try await gql.query(
            ProjectMutations.deleteField,
            variables: ["fieldId": .string(fieldId)])
        let f = response.deleteProjectV2Field.projectV2Field
        Stdio.print("\(ANSI.green("✓")) Deleted field \(f.name)")
    }
}
