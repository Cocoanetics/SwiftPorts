import ArgumentParser
import Sandbox

struct StashList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the stash entries that you currently have."
    )

    func run() async throws {
        let entries = try await CommandContext.gitClient().stashList()
        // Real git: silent (exit 0) when there are no entries. Each
        // entry rendered as `stash@{N}: <message>`.
        for entry in entries {
            Stdio.print("stash@{\(entry.index)}: \(entry.message)")
        }
    }
}
