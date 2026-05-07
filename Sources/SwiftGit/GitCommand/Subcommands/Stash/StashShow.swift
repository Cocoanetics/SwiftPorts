import ArgumentParser
import Sandbox

struct StashShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show the changes recorded in a stash entry."
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
        let stats = try await client.stashShow(index: idx)

        // Real git's `stash show` prints a short stat: " <path> | <n> [+-]"
        // per file, then a summary line. We emit just the summary —
        // matches the trailing line real git always prints.
        var summary = " \(stats.filesChanged) file\(stats.filesChanged == 1 ? "" : "s") changed"
        if stats.insertions > 0 {
            summary += ", \(stats.insertions) insertion\(stats.insertions == 1 ? "" : "s")(+)"
        }
        if stats.deletions > 0 {
            summary += ", \(stats.deletions) deletion\(stats.deletions == 1 ? "" : "s")(-)"
        }
        Stdio.print(summary)
    }
}
