import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct PrLock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Lock a pull request."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    @Option(name: .customLong("reason"),
            help: "Lock reason: off-topic, too heated, resolved, spam.")
    var reason: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        // PR lock endpoint is also under /issues/{n}/lock — they share
        // the issues lock subsystem in the API.
        try await client.send(
            method: .put,
            path: "repos/\(target.slug)/issues/\(number)/lock",
            body: LockRequest(lockReason: reason))
        Stdio.print("\(ANSI.green("✓")) Locked PR #\(number)")
    }
}

struct PrUnlock: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "Unlock a pull request."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        try await client.delete("repos/\(target.slug)/issues/\(number)/lock")
        Stdio.print("\(ANSI.green("✓")) Unlocked PR #\(number)")
    }
}
