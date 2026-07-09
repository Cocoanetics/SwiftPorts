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

    @Option(name: .customShort("b"),
            help: "Create a new branch named BRANCH.")
    var newBranch: String?

    @Argument(help: "Path for the new working tree.")
    var path: String

    @Argument(help: "Commit-ish to check out. Existing local branches are supported.")
    var commitish: String?

    func run() async throws {
        let client = CommandContext.gitClient()
        let target = Shell.resolve(path)
        let branches = (try? await client.localBranches()) ?? []
        let branchName: String
        let existed: Bool
        if let newBranch {
            guard !newBranch.isEmpty else {
                throw CLIError.stderr("fatal: invalid reference: \(path)", exitCode: 128)
            }
            if branches.contains(newBranch) {
                throw CLIError.stderr(
                    "fatal: a branch named '\(newBranch)' already exists",
                    exitCode: 128)
            }
            if let commitish, commitish != "HEAD" {
                throw CLIError.stderr(
                    "fatal: git worktree add -b <branch> <path> <commit-ish> is not supported yet",
                    exitCode: 128)
            }
            branchName = newBranch
            existed = false
        } else if let commitish {
            guard branches.contains(commitish) else {
                throw CLIError.stderr(
                    "fatal: unsupported commit-ish '\(commitish)' for git worktree add",
                    exitCode: 128)
            }
            branchName = commitish
            existed = true
        } else {
            branchName = target.lastPathComponent
            existed = branches.contains(branchName)
        }
        guard !branchName.isEmpty else {
            throw CLIError.stderr("fatal: invalid reference: \(path)", exitCode: 128)
        }

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
