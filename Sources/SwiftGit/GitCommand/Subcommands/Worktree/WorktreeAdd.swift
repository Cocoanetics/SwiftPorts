import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

struct WorktreeAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a linked working tree."
    )

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: "Checkout even if the target path already exists.")
    var force: Bool = false

    @Argument(help: "Path for the new working tree.")
    var path: String

    @Argument(help: "Branch to check out. Defaults to PATH's basename.")
    var branch: String?

    func run() async throws {
        let client = CommandContext.gitClient()
        let target = Shell.resolve(path)
        let branchName = branch ?? target.lastPathComponent
        guard !branchName.isEmpty else {
            throw CLIError.stderr("fatal: invalid reference: \(path)", exitCode: 128)
        }

        let existed = (try? await client.localBranches().contains(branchName)) ?? false
        let head = try? await client.log(.init(maxCount: 1)).first
        let stderr = Shell.current.stderr
        let action = existed ? "checking out" : "new branch"
        stderr.write(Data("Preparing worktree (\(action) '\(branchName)')\n".utf8))

        try await client.worktreeAdd(path: target, branch: branchName, force: force)

        if let head {
            stderr.write(Data("HEAD is now at \(head.shortSHA) \(head.subject)\n".utf8))
        }
    }
}
