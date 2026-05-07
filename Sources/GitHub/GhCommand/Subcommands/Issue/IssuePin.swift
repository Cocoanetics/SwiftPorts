import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct IssuePin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pin",
        abstract: "Pin an issue to the top of the issues tab.",
        discussion: "GitHub allows up to 3 pinned issues per repo."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        _ = try await client.raw(
            method: .put,
            path: "repos/\(target.slug)/issues/\(number)/pin")
        Stdio.print("\(ANSI.green("✓")) Pinned #\(number)")
    }
}

struct IssueUnpin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpin",
        abstract: "Unpin a pinned issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        try await client.delete("repos/\(target.slug)/issues/\(number)/pin")
        Stdio.print("\(ANSI.green("✓")) Unpinned #\(number)")
    }
}
