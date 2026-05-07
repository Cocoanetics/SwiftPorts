import ArgumentParser
import Sandbox

struct StashBranch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "branch",
        abstract: "Create a new branch from the parent of a stash and apply it."
    )

    @Argument(help: "New branch name to create.")
    var name: String

    @Argument(help: "Stash reference, e.g. `stash@{0}` or `0`. Defaults to most recent.")
    var stash: String?

    func run() async throws {
        let idx = try parseStashIndex(stash)
        let client = CommandContext.gitClient()
        let entries = try await client.stashList()
        if entries.isEmpty {
            throw CLIError.stderr("No stash entries found.", exitCode: 1)
        }
        try await client.stashBranch(name: name, index: idx)
        // Real git emits "Switched to a new branch '<name>'" via the
        // checkout machinery; mirror it.
        Stdio.print("Switched to a new branch '\(name)'")
    }
}
