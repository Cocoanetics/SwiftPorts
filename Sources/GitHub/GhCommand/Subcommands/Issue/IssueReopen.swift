import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct IssueReopen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reopen",
        abstract: "Reopen a closed issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let issue: Issue = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)/issues/\(number)",
            body: IssueStateUpdateRequest.reopen())
        Stdio.print("✓ Reopened #\(issue.number)")
    }
}
