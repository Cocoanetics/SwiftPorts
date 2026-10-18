import ArgumentParser
import ShellKit
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

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress the merge summary; conflicts are still reported.")
    var quiet: Bool = false

    @Argument(help: "Commits to merge into the current branch; more than one make an octopus merge.")
    var refs: [String] = []

    func validate() throws {
        let count = [ff, noFF, ffOnly].filter { $0 }.count
        if count > 1 {
            throw ValidationError("only one of --ff / --no-ff / --ff-only may be set")
        }
        if refs.isEmpty {
            throw ValidationError("Missing expected argument '<refs> ...'")
        }
    }

    func run() async throws {
        let mode: FastForwardMode = noFF ? .never : (ffOnly ? .onlyFastForward : .auto)
        let client = CommandContext.gitClient()

        guard refs.count == 1, let ref = refs.first else {
            let heads: MergeHeads
            do {
                heads = try await client.mergeHeads(reducing: refs)
            } catch let err as Libgit2Error where err.message.hasSuffix("not something we can merge") {
                throw CLIError.stderr(err.message, exitCode: 1)
            }
            if (try? await client.resolveOID("HEAD")) == nil {
                throw CLIError.stderr("fatal: Can merge only exactly one commit into empty head", exitCode: 128)
            }
            var names: [String] = []
            for head in heads.heads { names.append(try await client.mergeName(head)) }
            var message = self.message
            if message == nil { message = try await client.mergeMessage(describing: names) }
            try await Self.merge(heads: heads, mode: mode, message: message ?? "", client: client, quiet: quiet)
            return
        }

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

        if !quiet {
            try Self.printOutcome(outcome)
        } else if case .conflicts = outcome {
            try Self.printOutcome(outcome)
        }
    }

    /// Merge what's left of several heads once ``GitClient/mergeHeads(reducing:)``
    /// reduced them, as `git merge` does: nothing left is up to date, one
    /// is an ordinary merge, more an octopus merge, which can't
    /// fast-forward.
    static func merge(
        heads: MergeHeads, mode: FastForwardMode, message: String,
        client: SwiftGit.GitClient, quiet: Bool
    ) async throws {
        if heads.heads.isEmpty {
            if !quiet { Shell.print("Already up to date.") }
            return
        }
        if heads.heads.count == 1 {
            let outcome: MergeOutcome
            do {
                // git ends a message with a newline.
                outcome = try await client.merge(ref: heads.heads[0], fastForward: mode,
                                                 message: message + "\n", author: nil)
            } catch let err as Libgit2Error where err.message.contains("Not possible to fast-forward") {
                throw try await Pull.notPossibleToFastForward(client: client)
            }
            if case .conflicts(let paths) = outcome {
                try await Pull.writeMergeMessage(message, conflicts: paths, client: client)
            }
            if !quiet {
                try printOutcome(outcome)
            } else if case .conflicts = outcome {
                try printOutcome(outcome)
            }
            return
        }
        if mode == .onlyFastForward { throw try await Pull.notPossibleToFastForward(client: client) }
        let result = try await client.octopusMerge(
            heads: heads.heads, noFastForward: mode == .never, message: message)
        try printOctopus(result, quiet: quiet)
    }

    /// What git's octopus strategy says, step by step, then how the
    /// merge ended: `git-merge-octopus` and `git-merge-one-file` write
    /// the steps to stdout and their errors to stderr, as they happen.
    static func printOctopus(_ result: OctopusMergeResult, quiet: Bool) throws {
        let stderr = Shell.current.stderr
        func error(_ line: String) { stderr.write(Data((line + "\n").utf8)) }
        for step in result.steps {
            switch step.kind {
            case .alreadyUpToDate: Shell.print("Already up to date with \(step.head)")
            case .fastForward: Shell.print("Fast-forwarding to: \(step.head)")
            case .merge: Shell.print("Trying simple merge with \(step.head)")
            }
            guard let automatic = step.automatic else { continue }
            Shell.print("Simple merge did not work, trying automatic merge.")
            for path in automatic {
                switch path {
                case .merged(let path):
                    Shell.print("Auto-merging \(path)")
                case .conflict(let path):
                    Shell.print("Auto-merging \(path)")
                    error("ERROR: content conflict in \(path)")
                case .addedInBoth(let path):
                    Shell.print("Added \(path) in both, but differently.")
                    error("ERROR: content conflict in \(path)")
                case .notHandled(let path, let base, let ours, let theirs):
                    error("ERROR: \(path): Not handling case \(base) -> \(ours) -> \(theirs)")
                }
            }
            if automatic.contains(where: \.failed) { error("fatal: merge program failed") }
        }

        let failed = "Merge with strategy octopus failed."
        switch result.outcome {
        case .mergeCommit(_, let summary, let added, let deleted):
            guard !quiet else { return }
            Shell.print("Merge made by the 'octopus' strategy.")
            Shell.print(summary)
            for line in added { Shell.print(line) }
            for line in deleted { Shell.print(line) }
        case .conflicts:
            Shell.print("Automatic merge failed; fix conflicts and then commit the result.")
            throw CLIError.stderr([], exitCode: 1)
        case .failed(let failure):
            switch failure {
            case .localChanges(let paths):
                Shell.print("Error: Your local changes to the following files would be overwritten by merge")
                for path in paths { Shell.print("    \(path)") }
                throw CLIError.stderr(failed, exitCode: 2)
            case .notUpToDate(let path):
                throw CLIError.stderr(["error: Entry '\(path)' not uptodate. Cannot merge.", failed], exitCode: 2)
            case .untrackedWouldBeOverwritten(let path):
                throw CLIError.stderr(
                    ["error: Untracked working tree file '\(path)' would be overwritten by merge.", failed],
                    exitCode: 2)
            case .noCommonCommit(let head):
                Shell.print("Unable to find common commit with \(head)")
                throw CLIError.stderr(failed, exitCode: 2)
            case .conflictsBeforeLastHead:
                Shell.print("Automated merge did not work.")
                Shell.print("Should not be doing an octopus.")
                throw CLIError.stderr(failed, exitCode: 2)
            }
        }
    }

    static func printOutcome(_ outcome: MergeOutcome) throws {
        switch outcome {
        case .alreadyUpToDate:
            Shell.print("Already up to date.")

        case .fastForward(let oldSHA, let newSHA, let summary, let added, let deleted):
            Shell.print("Updating \(String(oldSHA.prefix(7)))..\(String(newSHA.prefix(7)))")
            Shell.print("Fast-forward")
            Shell.print(summary)
            for line in added { Shell.print(line) }
            for line in deleted { Shell.print(line) }

        case .mergeCommit(_, let summary, let added, let deleted):
            // Modern git (≥ 2.34) defaults to the 'ort' strategy. We
            // print the same string so output matches what users see today.
            Shell.print("Merge made by the 'ort' strategy.")
            Shell.print(summary)
            for line in added { Shell.print(line) }
            for line in deleted { Shell.print(line) }

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
