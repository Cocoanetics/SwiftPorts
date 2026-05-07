import ArgumentParser
import Sandbox
import Foundation
import HTTPTypes
import GitHub

struct PrDiff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Print the unified diff for a pull request."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    @Flag(name: .long, help: "Patch format instead of diff.")
    var patch: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let mediaType = patch ? "application/vnd.github.patch" : "application/vnd.github.diff"
        let client = try await CommandContext.apiClient()
        var headers = HTTPFields()
        headers[.accept] = mediaType
        let response = try await client.raw(
            method: .get,
            path: "repos/\(target.slug)/pulls/\(number)",
            extraHeaders: headers)
        Stdio.stdout.write(response.body)
    }
}
