import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct IssueLock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Lock an issue (limits new comments to collaborators)."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    @Option(name: .customLong("reason"),
            help: "Lock reason: off-topic, too heated, resolved, spam.")
    var reason: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        try await client.send(
            method: .put,
            path: "repos/\(target.slug)/issues/\(number)/lock",
            body: LockRequest(lockReason: reason))
        Stdio.print("\(ANSI.green("✓")) Locked #\(number)")
    }
}

struct IssueUnlock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "Unlock an issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        try await client.delete("repos/\(target.slug)/issues/\(number)/lock")
        Stdio.print("\(ANSI.green("✓")) Unlocked #\(number)")
    }
}
