import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct IssueCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("title")], help: "Issue title (required).")
    var title: String

    @Option(name: [.short, .customLong("body")],
            help: "Issue body. Use - to read from stdin.")
    var body: String?

    @Option(name: [.short, .customLong("label")],
            parsing: .singleValue,
            help: "Add a label; repeatable.")
    var labels: [String] = []

    @Option(name: [.short, .customLong("assignee")],
            parsing: .singleValue,
            help: "Assignee login; repeatable.")
    var assignees: [String] = []

    @Option(name: [.customShort("m"), .customLong("milestone")],
            help: "Milestone number to assign.")
    var milestone: Int?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let resolvedBody = try resolveBody()
        let request = IssueCreateRequest(
            title: title,
            body: resolvedBody,
            assignees: assignees.isEmpty ? nil : assignees,
            labels: labels.isEmpty ? nil : labels,
            milestone: milestone
        )
        let client = try await CommandContext.apiClient()
        let issue: Issue = try await client.send(
            method: .post,
            path: "repos/\(target.slug)/issues",
            body: request)

        Stdio.print("Created issue #\(issue.number): \(issue.title)")
        Stdio.print(issue.htmlUrl.absoluteString)
    }

    private func resolveBody() throws -> String? {
        guard let body else { return nil }
        if body == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }
        return body
    }
}
