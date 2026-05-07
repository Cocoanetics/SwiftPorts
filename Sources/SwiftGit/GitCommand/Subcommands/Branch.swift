import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Branch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "branch",
        abstract: "List, create, delete, or rename branches.",
        discussion: """
            Forms supported:
              git branch                       list local branches
              git branch --show-current        print HEAD's branch name
              git branch --upstream <local>    print upstream tracking ref
              git branch -d <name>             delete (must be merged into HEAD)
              git branch -D <name>             force-delete
              git branch -m [<old>] <new>      rename
              git branch -M [<old>] <new>      force-rename (overwrites)
            """
    )

    @Flag(name: .customLong("show-current"),
          help: "Print the current branch name and exit.")
    var showCurrent: Bool = false

    @Option(name: .customLong("upstream"),
            help: "Print the upstream tracking branch of LOCAL_BRANCH (extension; not real git).",
            transform: { $0 })
    var upstream: String?

    @Flag(name: .customShort("d"),
          help: "Delete a fully-merged branch.")
    var delete: Bool = false

    @Flag(name: .customShort("D"),
          help: "Force-delete (skip the merged check).")
    var forceDelete: Bool = false

    @Flag(name: .customShort("m"),
          help: "Rename a branch.")
    var rename: Bool = false

    @Flag(name: .customShort("M"),
          help: "Force-rename (overwrite existing).")
    var forceRename: Bool = false

    @Argument(parsing: .captureForPassthrough,
              help: "Branch name(s) for delete / rename forms.")
    var rest: [String] = []

    func run() async throws {
        let client = CommandContext.gitClient()

        if let local = upstream {
            if let upstream = try await client.upstreamBranch(of: local) {
                Stdio.print(upstream)
            }
            return
        }

        if delete || forceDelete {
            for name in rest {
                do {
                    try await client.branchDelete(
                        name: name, force: forceDelete)
                } catch let err as Libgit2Error
                    where err.message.contains("not fully merged") {
                    throw CLIError.stderr(
                        "error: the branch '\(name)' is not fully merged.\nIf you are sure you want to delete it, run 'git branch -D \(name)'.",
                        exitCode: 1)
                } catch let err as Libgit2Error
                    where err.message.contains("not found") {
                    throw CLIError.stderr(
                        "error: branch '\(name)' not found.", exitCode: 1)
                }
                Stdio.print("Deleted branch \(name).")
            }
            return
        }

        if rename || forceRename {
            let force = forceRename
            switch rest.count {
            case 1:
                try await client.branchRename(to: rest[0], force: force)
            case 2:
                try await client.branchRename(from: rest[0], to: rest[1], force: force)
            default:
                throw CLIError.stderr(
                    "fatal: -m takes [<old>] <new>", exitCode: 128)
            }
            return
        }

        if showCurrent {
            if let current = try await client.currentBranch() {
                Stdio.print(current)
            }
            return
        }

        // Default: list local branches with `*` marker.
        let current = try await client.currentBranch()
        let names = try await client.localBranches()
        for name in names.sorted() {
            Stdio.print(name == current ? "* \(name)" : "  \(name)")
        }
    }
}
