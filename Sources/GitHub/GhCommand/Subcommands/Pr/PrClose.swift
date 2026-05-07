import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct PrClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a pull request without merging."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        // PRs share the issue-state PATCH endpoint shape.
        let pr: PullRequest = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)/pulls/\(number)",
            body: ["state": "closed"])
        Stdio.print("\(ANSI.green("✓")) Closed #\(pr.number)")
    }
}
