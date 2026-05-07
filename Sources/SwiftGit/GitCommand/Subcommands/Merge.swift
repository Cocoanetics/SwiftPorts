import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Merge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Join two or more development histories together."
    )

    @Flag(name: .customLong("ff"),
          help: "Allow fast-forward (the default).")
    var ff: Bool = false

    @Flag(name: .customLong("no-ff"),
          help: "Always create a merge commit, even when fast-forward is possible.")
    var noFF: Bool = false

    @Flag(name: .customLong("ff-only"),
          help: "Refuse to merge unless fast-forward is possible.")
    var ffOnly: Bool = false

    @Option(name: [.customShort("m"), .customLong("message")],
            help: "Override the auto-generated merge commit message.")
    var message: String?

    @Argument(help: "Ref to merge into the current branch.")
    var ref: String

    func validate() throws {
        let count = [ff, noFF, ffOnly].filter { $0 }.count
        if count > 1 {
            throw ValidationError("only one of --ff / --no-ff / --ff-only may be set")
        }
    }

    func run() async throws {
        let mode: FastForwardMode = noFF ? .never : (ffOnly ? .onlyFastForward : .auto)
        let client = CommandContext.gitClient()

        let outcome: MergeOutcome
        do {
            outcome = try await client.merge(
                ref: ref, fastForward: mode, message: message, author: nil)
        } catch let err as Libgit2Error
            where err.message.contains("not something we can merge") {
            throw CLIError.stderr(
                "merge: \(ref) - not something we can merge", exitCode: 1)
        } catch let err as Libgit2Error
            where err.message.contains("Not possible to fast-forward") {
            throw CLIError.stderr(
                "fatal: Not possible to fast-forward, aborting.", exitCode: 128)
        }

        try Self.printOutcome(outcome)
    }

    static func printOutcome(_ outcome: MergeOutcome) throws {
        switch outcome {
        case .alreadyUpToDate:
            Stdio.print("Already up to date.")

        case .fastForward(let oldSHA, let newSHA, let summary, let added, let deleted):
            Stdio.print("Updating \(String(oldSHA.prefix(7)))..\(String(newSHA.prefix(7)))")
            Stdio.print("Fast-forward")
            Stdio.print(summary)
            for line in added { Stdio.print(line) }
            for line in deleted { Stdio.print(line) }

        case .mergeCommit(_, let summary, let added, let deleted):
            // Modern git (≥ 2.34) defaults to the 'ort' strategy. We
            // print the same string so output matches what users see today.
            Stdio.print("Merge made by the 'ort' strategy.")
            Stdio.print(summary)
            for line in added { Stdio.print(line) }
            for line in deleted { Stdio.print(line) }

        case .conflicts(let paths):
            // All three line groups go to stderr — that's where real git
            // writes them, and it ensures they show up in insertion order
            // when piped (stdout is line-buffered, stderr isn't).
            var lines: [String] = []
            for path in paths { lines.append("Auto-merging \(path)") }
            for path in paths { lines.append("CONFLICT (content): Merge conflict in \(path)") }
            lines.append("Automatic merge failed; fix conflicts and then commit the result.")
            throw CLIError.stderr(lines, exitCode: 1)
        }
    }
}
