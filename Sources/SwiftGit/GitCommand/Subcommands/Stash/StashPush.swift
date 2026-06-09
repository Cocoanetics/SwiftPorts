import ArgumentParser
import ShellKit
import SwiftGit
import libgit2

struct StashPush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Save your local modifications to a new stash entry."
    )

    @Option(name: [.customShort("m"), .customLong("message")],
            help: "Stash message describing the saved state.")
    var message: String?

    @Flag(name: [.customShort("u"), .customLong("include-untracked")],
          help: "Also stash untracked files.")
    var includeUntracked: Bool = false

    @Flag(name: [.customShort("a"), .customLong("all")],
          help: "Also stash ignored files.")
    var all: Bool = false

    @Flag(name: [.customShort("k"), .customLong("keep-index")],
          help: "Leave the index intact in the working directory.")
    var keepIndex: Bool = false

    func run() async throws {
        var flags: StashSaveFlags = .default
        if includeUntracked { flags.insert(.includeUntracked) }
        if all { flags.formUnion([.includeUntracked, .includeIgnored]) }
        if keepIndex { flags.insert(.keepIndex) }

        let client = CommandContext.gitClient()
        do {
            _ = try await client.stashSave(message: message, author: nil, flags: flags)
        } catch let err as Libgit2Error
            where err.message.lowercased().contains("nothing to stash")
            || err.code == GIT_ENOTFOUND.rawValue {
            // Real git: stdout + exit 0.
            Shell.print("No local changes to save")
            return
        }

        // Match real-git's confirmation: "Saved working directory and
        // index state On <branch>: <message>" when -m was given,
        // "WIP on <branch>: <sha> <subject>" otherwise. We pull the
        // latest stash entry to print exactly what was recorded.
        let entries = try await client.stashList()
        guard let latest = entries.first else { return }
        Shell.print("Saved working directory and index state \(latest.message)")
    }
}
