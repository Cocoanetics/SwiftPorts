import ArgumentParser

struct WorktreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktree",
        abstract: "Manage multiple working trees.",
        subcommands: [
            WorktreeAdd.self,
            WorktreeList.self,
            WorktreeRemove.self,
        ]
    )
}
