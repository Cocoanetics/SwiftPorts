import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct ProjectItemEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "item-edit",
        abstract: "Set or clear a field's value on a ProjectV2 item.",
        discussion: """
        Pass exactly one value flag (--text / --number / --date /
        --single-select-option-id / --iteration-id), or --clear to
        unset the field.

        Field IDs come from `gh project field-list`. Item IDs come
        from `gh project item-list --json`.
        """
    )

    @Argument(help: "Project number.") var number: Int
    @Option(name: [.customShort("o"), .customLong("owner")]) var owner: String?
    @Flag(name: [.long, .customLong("org")]) var asOrg: Bool = false

    @Option(name: .customLong("item-id"), help: "Item node ID.")
    var itemId: String

    @Option(name: .customLong("field-id"), help: "Field node ID.")
    var fieldId: String

    @Option(name: .customLong("text")) var text: String?
    @Option(name: .customLong("number")) var number_value: Double?
    @Option(name: .customLong("date"),
            help: "ISO 8601 date, e.g. 2026-05-03.")
    var date: String?
    @Option(name: .customLong("single-select-option-id"))
    var singleSelectOptionId: String?
    @Option(name: .customLong("iteration-id"))
    var iterationId: String?

    @Flag(name: .customLong("clear"),
          help: "Clear the field's value instead of setting one.")
    var clear: Bool = false

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let projectId = try await ProjectIDs.projectID(
            owner: ownerKind(owner: owner, asOrg: asOrg),
            number: number, gql: gql)

        if clear {
            let _: ClearItemFieldValueResponse = try await gql.query(
                ProjectMutations.clearItemFieldValue,
                variables: [
                    "projectId": .string(projectId),
                    "itemId": .string(itemId),
                    "fieldId": .string(fieldId),
                ])
            Stdio.print("\(ANSI.green("✓")) Cleared field \(fieldId) on item \(itemId)")
            return
        }

        let valueObject = try buildValue()
        let _: UpdateItemFieldValueResponse = try await gql.query(
            ProjectMutations.updateItemFieldValue,
            variables: [
                "projectId": .string(projectId),
                "itemId": .string(itemId),
                "fieldId": .string(fieldId),
                "value": valueObject,
            ])
        Stdio.print("\(ANSI.green("✓")) Updated field \(fieldId) on item \(itemId)")
    }

    private func buildValue() throws -> GraphQLValue {
        let provided: [(String, GraphQLValue)] = [
            text.map { ("text", .string($0)) },
            number_value.map { ("number", .double($0)) },
            date.map { ("date", .string($0)) },
            singleSelectOptionId.map { ("singleSelectOptionId", .string($0)) },
            iterationId.map { ("iterationId", .string($0)) },
        ].compactMap { $0 }

        guard provided.count == 1 else {
            throw ValidationError(
                "Pass exactly one of --text / --number / --date / " +
                "--single-select-option-id / --iteration-id (or --clear).")
        }
        return .object([provided[0].0: provided[0].1])
    }
}
