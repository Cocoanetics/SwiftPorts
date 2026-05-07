import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Rebase: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebase",
        abstract: "Reapply commits on top of another base tip.",
        discussion: """
            Replays the current branch's commits since their merge-base
            with `<upstream>` on top of `<upstream>` (or `<onto>` if
            given). On conflict, the rebase pauses; resolve, `git add`,
            then `git rebase --continue`. Use `--abort` to undo.
            """
    )

    @Flag(name: .customLong("continue"),
          help: "Resume an in-progress rebase after resolving conflicts.")
    var continueRebase: Bool = false

    @Flag(name: .customLong("skip"),
          help: "Skip the current commit and resume the rebase.")
    var skip: Bool = false

    @Flag(name: .customLong("abort"),
          help: "Cancel an in-progress rebase and restore the prior state.")
    var abort: Bool = false

    @Option(name: .customLong("onto"),
            help: "Replay commits onto NEWBASE instead of `<upstream>`.")
    var onto: String?

    @Argument(help: "Upstream branch to rebase against. Required unless --continue / --abort.")
    var upstream: String?

    func validate() throws {
        let resumeFlags = [continueRebase, skip, abort].filter { $0 }.count
        if resumeFlags > 1 {
            throw ValidationError("--continue / --skip / --abort are mutually exclusive")
        }
        let resuming = resumeFlags == 1
        if !resuming && upstream == nil {
            throw ValidationError("upstream argument is required")
        }
        if resuming && upstream != nil {
            throw ValidationError("upstream argument is not valid with --continue / --skip / --abort")
        }
    }

    func run() async throws {
        let client = CommandContext.gitClient()

        if abort {
            do {
                try await client.rebaseAbort()
            } catch let err as Libgit2Error
                where err.message.contains("no rebase in progress") {
                throw CLIError.stderr(
                    "fatal: no rebase in progress", exitCode: 128)
            }
            return
        }

        let outcome: RebaseOutcome
        do {
            if continueRebase {
                outcome = try await client.rebaseContinue(author: nil) { current, total in
                    Self.emitProgress(current: current, total: total)
                }
            } else if skip {
                outcome = try await client.rebaseSkip(author: nil) { current, total in
                    Self.emitProgress(current: current, total: total)
                }
            } else {
                outcome = try await client.rebase(
                    upstream: upstream!,
                    onto: onto,
                    author: nil) { current, total in
                    Self.emitProgress(current: current, total: total)
                }
            }
        } catch let err as Libgit2Error
            where err.message.contains("no rebase in progress") {
            throw CLIError.stderr(
                "fatal: no rebase in progress", exitCode: 128)
        }

        try Self.printOutcome(outcome)
    }

    /// Emit the per-step `Rebasing (i/n)\r` overwrite line to stderr.
    /// Real git puts `\r` AFTER each line so the next write overwrites
    /// it; the trailing `\r` also precedes the final success line, so
    /// "Successfully rebased…" lands on the same visual row.
    static func emitProgress(current: Int, total: Int) {
        let line = "Rebasing (\(current)/\(total))\r"
        Stdio.stderr.write(Data(line.utf8))
    }

    static func printOutcome(_ outcome: RebaseOutcome) throws {
        let stderr = Stdio.stderr
        switch outcome {
        case .alreadyUpToDate(let refName):
            // Real git: "Current branch <shorthand> is up to date." on
            // stderr, no progress line preceding it.
            let short = refName.flatMap(stripRefsHeads) ?? "HEAD"
            stderr.write(Data("Current branch \(short) is up to date.\n".utf8))

        case .completed(let refName, _):
            // Real git appends "Successfully rebased…" to the same
            // stderr write as the trailing `Rebasing (n/n)` progress —
            // no newline between them — then a final `\n` after the
            // ref name. Match exactly so capture-tests come out the same.
            stderr.write(Data("Successfully rebased and updated \(refName).\n".utf8))

        case .conflict(let sha, let subject, let paths):
            // Real git appends "Auto-merging…" right after the trailing
            // `\r` of the last progress line — no separating newline.
            // We send the first line directly and let CLIError write
            // the rest (each terminated with `\n`).
            var head = ""
            var rest: [String] = []
            for (i, p) in paths.enumerated() {
                if i == 0 { head = "Auto-merging \(p)" }
                else { rest.append("Auto-merging \(p)") }
            }
            stderr.write(Data(head.utf8))
            // Closing newline so CLIError lines start on a fresh row.
            stderr.write(Data("\n".utf8))

            var lines: [String] = rest
            for p in paths { lines.append("CONFLICT (content): Merge conflict in \(p)") }
            lines.append("error: could not apply \(sha)... \(subject)")
            lines.append(#"hint: Resolve all conflicts manually, mark them as resolved with"#)
            lines.append(#"hint: "git add/rm <conflicted_files>", then run "git rebase --continue"."#)
            lines.append(#"hint: You can instead skip this commit: run "git rebase --skip"."#)
            lines.append(#"hint: To abort and get back to the state before "git rebase", run "git rebase --abort"."#)
            lines.append(#"hint: Disable this message with "git config set advice.mergeConflict false""#)
            lines.append("Could not apply \(sha)... # \(subject)")
            throw CLIError.stderr(lines, exitCode: 1)
        }
    }

    private static func stripRefsHeads(_ refName: String) -> String? {
        let prefix = "refs/heads/"
        guard refName.hasPrefix(prefix) else { return refName }
        return String(refName.dropFirst(prefix.count))
    }
}
