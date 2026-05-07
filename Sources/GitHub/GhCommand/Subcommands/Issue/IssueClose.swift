import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct IssueClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close an issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    @Option(name: .customLong("reason"),
            help: "Close reason: completed, not_planned, duplicate.")
    var reason: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let request = IssueStateUpdateRequest.close(reason: reason)
        let client = try await CommandContext.apiClient()
        let issue: Issue = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)/issues/\(number)",
            body: request)
        Stdio.print("✓ Closed #\(issue.number)")
    }
}
