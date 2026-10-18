import ArgumentParser
import Foundation
import SwiftGit

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Fetch from and integrate with another repository or branch.",
        discussion: """
            `pull` is `fetch` followed by `merge`. Today this command
            mirrors the FF/`--no-ff`/`--ff-only` behaviour of `merge`
            against the just-fetched `<remote>/<branch>` ref.
            """
    )

    @Flag(name: [.customShort("r"), .customLong("rebase")],
          help: "Rebase the current branch onto the upstream instead of merging.")
    var rebase: Bool = false

    @Flag(name: .customLong("ff"),
          help: "Allow fast-forward (the default; ignored with --rebase).")
    var ff: Bool = false

    @Flag(name: .customLong("no-ff"),
          help: "Always create a merge commit (ignored with --rebase).")
    var noFF: Bool = false

    @Flag(name: .customLong("ff-only"),
          help: "Refuse to merge unless fast-forward is possible (ignored with --rebase).")
    var ffOnly: Bool = false

    @Option(name: [.customShort("m"), .customLong("message")],
            help: "Merge commit message (3-way merges only).")
    var message: String?

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress progress and the merge summary; conflicts are still reported.")
    var quiet: Bool = false

    @Argument(help: "Remote name. Defaults to `origin`.")
    var remote: String = "origin"

    @Argument(help: "Branch name. Defaults to the current branch.")
    var branch: String?

    func validate() throws {
        let count = [ff, noFF, ffOnly].filter { $0 }.count
        if count > 1 {
            throw ValidationError("only one of --ff / --no-ff / --ff-only may be set")
        }
        if rebase && (noFF || ffOnly) {
            throw ValidationError("--rebase is incompatible with --no-ff / --ff-only")
        }
    }

    func run() async throws {
        let client = CommandContext.gitClient(quiet: quiet)

        if rebase {
            // pull --rebase: fetch then rebase against <remote>/<branch>.
            let outcome = try await client.pullRebase(
                remote: remote, branch: branch, author: nil) { current, total in
                if !quiet { Rebase.emitProgress(current: current, total: total) }
            }
            if quiet, case .conflict = outcome {
                try Rebase.printOutcome(outcome)
            } else if !quiet {
                try Rebase.printOutcome(outcome)
            }
            return
        }

        let mode: FastForwardMode = noFF ? .never : (ffOnly ? .onlyFastForward : .auto)
        let outcome: MergeOutcome
        do {
            outcome = try await client.pull(
                remote: remote, branch: branch,
                fastForward: mode, message: message, author: nil)
        } catch let err as Libgit2Error
            where err.message.contains("Not possible to fast-forward") {
            throw CLIError.stderr(
                "fatal: Not possible to fast-forward, aborting.", exitCode: 128)
        }

        if quiet, case .conflicts = outcome {
            try Merge.printOutcome(outcome)
        } else if !quiet {
            try Merge.printOutcome(outcome)
        }
    }
}
