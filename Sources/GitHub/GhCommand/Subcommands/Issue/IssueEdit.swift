import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct IssueEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit an issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    @Option(name: [.short, .customLong("title")], help: "New title.")
    var title: String?

    @Option(name: [.short, .customLong("body")], help: "New body. Use - for stdin.")
    var body: String?

    @Option(name: [.short, .customLong("label")],
            parsing: .singleValue,
            help: "Replace labels (repeatable). Use --add-label / --remove-label for delta edits.")
    var labels: [String] = []

    @Option(name: [.short, .customLong("assignee")],
            parsing: .singleValue,
            help: "Replace assignees (repeatable).")
    var assignees: [String] = []

    @Option(name: [.customShort("m"), .customLong("milestone")],
            help: "Milestone number to assign; pass 0 to clear.")
    var milestone: Int?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let resolvedBody: String?
        if body == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            resolvedBody = String(data: data, encoding: .utf8)
        } else {
            resolvedBody = body
        }
        let request = IssueUpdateRequest(
            title: title,
            body: resolvedBody,
            labels: labels.isEmpty ? nil : labels,
            assignees: assignees.isEmpty ? nil : assignees,
            milestone: milestone)
        let client = try await CommandContext.apiClient()
        let updated: Issue = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)/issues/\(number)",
            body: request)
        Stdio.print("\(ANSI.green("✓")) Edited #\(updated.number)")
    }
}
