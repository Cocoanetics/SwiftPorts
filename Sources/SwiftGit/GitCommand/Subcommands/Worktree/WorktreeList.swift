import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

struct WorktreeList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List details of each working tree."
    )

    @Flag(name: .customLong("porcelain"),
          help: "Emit stable machine-readable output.")
    var porcelain: Bool = false

    func run() async throws {
        let entries = try await CommandContext.gitClient().worktreeList()
        if porcelain {
            printPorcelain(entries)
        } else {
            printDefault(entries)
        }
    }

    private func printDefault(_ entries: [GitWorktreeInfo]) {
        let paths = entries.map { displayPath($0.path) }
        let width = paths.map(\.count).max() ?? 0
        for (entry, path) in zip(entries, paths) {
            let padded = path.padding(toLength: width, withPad: " ", startingAt: 0)
            let head = entry.head.map { String($0.prefix(7)) } ?? "0000000"
            let label = entry.branch.map { "[\($0)]" } ?? "(detached HEAD)"
            Shell.print("\(padded)  \(head) \(label)")
        }
    }

    private func printPorcelain(_ entries: [GitWorktreeInfo]) {
        for (index, entry) in entries.enumerated() {
            if index > 0 { Shell.print("") }
            Shell.print("worktree \(displayPath(entry.path))")
            if let head = entry.head {
                Shell.print("HEAD \(head)")
            }
            if let branch = entry.branch {
                Shell.print("branch refs/heads/\(branch)")
            } else {
                Shell.print("detached")
            }
            if entry.isLocked {
                Shell.print("locked")
            }
            if entry.isPrunable {
                Shell.print("prunable")
            }
        }
    }

    private func displayPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
