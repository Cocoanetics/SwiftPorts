import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

struct WorktreeRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a linked working tree."
    )

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: "Remove even with local changes or a lock.")
    var force: Bool = false

    @Argument(help: "Working tree path or name to remove.")
    var worktree: String

    func run() async throws {
        let client = CommandContext.gitClient()
        let entries = try await client.worktreeList()
        let resolved = Shell.resolve(worktree).standardizedFileURL.path

        guard let match = entries.first(where: { entry in
            guard !entry.isMain else { return false }
            if entry.name == worktree { return true }
            return entry.path.standardizedFileURL.path == resolved
        }) else {
            throw CLIError.stderr(
                "fatal: '\(worktree)' is not a working tree", exitCode: 128)
        }

        try await client.worktreeRemove(name: match.name, force: force)
    }
}
