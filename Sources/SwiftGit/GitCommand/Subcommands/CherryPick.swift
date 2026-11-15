import ArgumentParser
import ShellKit
import Foundation
import SwiftGit

struct CherryPick: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cherry-pick",
        abstract: "Apply the changes introduced by an existing commit."
    )

    @Flag(name: .customLong("continue"),
          help: "Resume an in-progress cherry-pick after resolving conflicts.")
    var continueCherry: Bool = false

    @Flag(name: .customLong("abort"),
          help: "Cancel the cherry-pick and restore the prior state.")
    var abort: Bool = false

    @Flag(name: .customLong("skip"),
          help: "Skip the current commit and clean up state.")
    var skip: Bool = false

    @Option(name: .customLong("gpg-sign"),
            help: "GPG-sign commits (-S[<keyid>], --gpg-sign[=<keyid>], --no-gpg-sign).")
    var gpgSign: [String] = []

    @Argument(help: "Commit-ish to cherry-pick.")
    var commit: String?

    func validate() throws {
        let resume = [continueCherry, abort, skip].filter { $0 }.count
        if resume > 1 {
            throw ValidationError("--continue / --abort / --skip are mutually exclusive")
        }
        if resume == 0 && commit == nil {
            throw ValidationError("commit argument is required")
        }
        if resume == 1 && commit != nil {
            throw ValidationError("commit argument is not valid with --continue / --abort / --skip")
        }
    }

    func run() async throws {
        let client = CommandContext.gitClient()

        if abort {
            do { try await client.cherryPickAbort() }
            catch let err as Libgit2Error
                where err.message.contains("no cherry-pick in progress") {
                throw CLIError.stderr(
                    "fatal: no cherry-pick or revert in progress", exitCode: 128)
            }
            return
        }

        if skip {
            do { try await client.cherryPickSkip() }
            catch let err as Libgit2Error
                where err.message.contains("no cherry-pick in progress") {
                throw CLIError.stderr(
                    "fatal: no cherry-pick or revert in progress", exitCode: 128)
            }
            return
        }

        let outcome: CherryPickOutcome
        do {
            if continueCherry {
                outcome = try await client.cherryPickContinue(sign: GPGSign.mode(gpgSign))
            } else {
                outcome = try await client.cherryPick(commit!, sign: GPGSign.mode(gpgSign))
            }
        } catch let failure as SwiftGit.GitClient.SigningFailure {
            throw CLIError.stderr(failure.fatal.map { ["fatal: \($0)"] }
                ?? ["error: failed to write commit object", "fatal: cherry-pick failed"], exitCode: 128)
        } catch let err as Libgit2Error
            where err.message.contains("no cherry-pick in progress") {
            throw CLIError.stderr(
                "fatal: no cherry-pick or revert in progress", exitCode: 128)
        }

        try Self.printOutcome(outcome)
    }

    static func printOutcome(_ outcome: CherryPickOutcome) throws {
        switch outcome {
        case .completed(_, let shortSHA, let branchName, let subject, let authorDate,
                        let summary, let added, let deleted):
            let branch = branchName ?? "detached HEAD"
            Shell.print("[\(branch) \(shortSHA)] \(subject)")
            // Real git's cherry-pick output surfaces the original
            // commit's author date as ` Date: <…>` because the new
            // commit inherits authorship — only the committer is "now".
            if !authorDate.isEmpty {
                Shell.print(" Date: \(authorDate)")
            }
            Shell.print(summary)
            for line in added { Shell.print(line) }
            for line in deleted { Shell.print(line) }

        case .conflict(let sha, let subject, let paths):
            // Mirror real git's stderr block (matches our merge/rebase
            // output verbatim apart from the hint wording).
            var lines: [String] = []
            for p in paths { lines.append("Auto-merging \(p)") }
            for p in paths { lines.append("CONFLICT (content): Merge conflict in \(p)") }
            lines.append("error: could not apply \(sha)... \(subject)")
            lines.append(#"hint: After resolving the conflicts, mark them with"#)
            lines.append(#"hint: "git add/rm <pathspec>", then run"#)
            lines.append(#"hint: "git cherry-pick --continue"."#)
            lines.append(#"hint: You can instead skip this commit with "git cherry-pick --skip"."#)
            lines.append(#"hint: To abort and get back to the state before "git cherry-pick","#)
            lines.append(#"hint: run "git cherry-pick --abort"."#)
            lines.append(#"hint: Disable this message with "git config set advice.mergeConflict false""#)
            throw CLIError.stderr(lines, exitCode: 1)

        case .cleared:
            break
        }
    }
}
