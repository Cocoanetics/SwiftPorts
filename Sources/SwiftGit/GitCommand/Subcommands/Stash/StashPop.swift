import ArgumentParser
import Sandbox
import Foundation

struct StashPop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pop",
        abstract: "Apply and remove a single stashed state."
    )

    @Flag(name: .customLong("index"),
          help: "Restore the index as well as the working tree.")
    var reinstateIndex: Bool = false

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

        try await client.stashPop(index: idx, reinstateIndex: reinstateIndex)
        // Real git's `pop` prints the verbose status block first, then
        // the `Dropped stash@{N}` tail.
        let report = try await client.status()
        Stdio.stdout.write(Data(report.verboseFormat().utf8))
        Stdio.print("Dropped stash@{\(idx)} (\(target.sha))")
    }
}
