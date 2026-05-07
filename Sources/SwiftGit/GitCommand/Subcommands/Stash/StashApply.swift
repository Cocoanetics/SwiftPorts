import ArgumentParser
import Sandbox
import Foundation

struct StashApply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a stashed state without removing it from the list."
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
        try await client.stashApply(index: idx, reinstateIndex: reinstateIndex)
        // Real git follows up with a `git status` block — the
        // verbose form, same wording as `git status` itself.
        let report = try await client.status()
        Stdio.stdout.write(Data(report.verboseFormat().utf8))
    }
}
