import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct PrUpdateBranch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-branch",
        abstract: "Bring the PR's head branch up to date with its base."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    @Option(name: .customLong("expected-head-sha"),
            help: "Refuse the update unless the head currently matches this SHA.")
    var expectedHeadSha: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        struct Body: Codable { var expectedHeadSha: String? }
        try await client.send(
            method: .put,
            path: "repos/\(target.slug)/pulls/\(number)/update-branch",
            body: Body(expectedHeadSha: expectedHeadSha))
        Stdio.print("\(ANSI.green("✓")) Update queued for PR #\(number)")
    }
}
