import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct PrEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a pull request."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    @Option(name: [.short, .customLong("title")], help: "New title.")
    var title: String?

    @Option(name: [.short, .customLong("body")], help: "New body. Use - for stdin.")
    var body: String?

    @Option(name: [.customShort("B"), .customLong("base")],
            help: "Change base branch.")
    var base: String?

    @Flag(name: .customLong("no-maintainer-edit"),
          help: "Disallow maintainer edits to your branch.")
    var noMaintainerEdit: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let resolvedBody: String?
        if body == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            resolvedBody = String(data: data, encoding: .utf8)
        } else {
            resolvedBody = body
        }
        let request = PullRequestUpdateRequest(
            title: title,
            body: resolvedBody,
            base: base,
            maintainerCanModify: noMaintainerEdit ? false : nil)
        let client = try await CommandContext.apiClient()
        let updated: PullRequest = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)/pulls/\(number)",
            body: request)
        Stdio.print("\(ANSI.green("✓")) Edited #\(updated.number)")
    }
}
