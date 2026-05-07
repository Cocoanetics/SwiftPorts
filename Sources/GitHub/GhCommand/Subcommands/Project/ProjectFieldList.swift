import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ProjectFieldListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "field-list",
        abstract: "List the fields (columns) configured on a ProjectV2."
    )

    @Argument(help: "Project number.")
    var number: Int

    @Option(name: [.customShort("o"), .customLong("owner")])
    var owner: String?

    @Flag(name: [.long, .customLong("org")])
    var asOrg: Bool = false

    @Option(name: [.short, .customLong("limit")]) var limit: Int = 100

    @Option(name: .customLong("format"),
            help: "Output format: {json}.")
    var format: ProjectFormat?

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let connection: ProjectFieldConnection
        if let owner {
            if asOrg {
                let response: ProjectFieldsResponse = try await gql.query(
                    ProjectMutations.orgProjectFields,
                    variables: [
                        "login": .string(owner),
                        "number": .int(number),
                        "first": .int(min(limit, 100)),
                    ])
                guard let p = response.organization?.projectV2 else {
                    throw ValidationError("No project #\(number) on org '\(owner)'.")
                }
                connection = p.fields
            } else {
                let response: ProjectFieldsResponse = try await gql.query(
                    ProjectMutations.userProjectFields,
                    variables: [
                        "login": .string(owner),
                        "number": .int(number),
                        "first": .int(min(limit, 100)),
                    ])
                guard let p = response.user?.projectV2 else {
                    throw ValidationError("No project #\(number) on user '\(owner)'.")
                }
                connection = p.fields
            }
        } else {
            let response: ProjectFieldsResponse = try await gql.query(
                ProjectMutations.viewerProjectFields,
                variables: [
                    "number": .int(number),
                    "first": .int(min(limit, 100)),
                ])
            guard let p = response.viewer?.projectV2 else {
                throw ValidationError("No project #\(number) for current user.")
            }
            connection = p.fields
        }

        if format == .json {
            let payload: [String: Any] = [
                "fields": connection.nodes.map { f -> [String: Any] in
                    [
                        "id": f.id,
                        "name": f.name,
                        "type": f.typename,
                    ]
                },
                "totalCount": connection.totalCount,
            ]
            Stdio.print(try ProjectJSONOutput.render(payload))
            return
        }
        if connection.nodes.isEmpty {
            Stdio.print("No fields."); return
        }
        for f in connection.nodes {
            let optionsCount = f.options?.count
            let extras = optionsCount.map { "\t(\($0) options)" } ?? ""
            Stdio.print("\(f.id)\t\(f.dataType)\t\(f.name)\(extras)")
        }
    }
}
