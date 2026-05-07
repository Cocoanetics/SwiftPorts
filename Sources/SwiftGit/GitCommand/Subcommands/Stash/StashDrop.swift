import ArgumentParser
import Sandbox

struct StashDrop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drop",
        abstract: "Remove a single stashed state from the stash list."
    )

    @Argument(help: "Stash reference, e.g. `stash@{0}` or `0`. Defaults to most recent.")
    var stash: String?

    func run() async throws {
        let idx = try parseStashIndex(stash)
        let client = CommandContext.gitClient()
        let entries = try await client.stashList()
        if entries.isEmpty {
            throw CLIError.stderr("No stash entries found.", exitCode: 1)
        }
        guard let target = entries.first(where: { $0.index == idx }) else {
            throw CLIError.stderr(
                "fatal: stash@{\(idx)} does not exist", exitCode: 128)
        }
        try await client.stashDrop(index: idx)
        Stdio.print("Dropped stash@{\(idx)} (\(target.sha))")
    }
}
