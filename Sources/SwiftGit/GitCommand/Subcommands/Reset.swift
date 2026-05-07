import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Reset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset current HEAD to the specified state.",
        discussion: """
            Three whole-tree forms:
              git reset [--mixed] [<commit>]   move HEAD + reset index
              git reset --soft <commit>        move HEAD only
              git reset --hard <commit>        move HEAD + index + workdir

            Per-path form (no HEAD movement):
              git reset [<commit>] -- <paths>  copy <paths> from <commit>'s tree
                                               into the index (unstage)
            """
    )

    @Flag(name: .customLong("soft"),
          help: "Move HEAD only; index + working tree untouched.")
    var soft: Bool = false

    @Flag(name: .customLong("mixed"),
          help: "Move HEAD + reset index (default).")
    var mixed: Bool = false

    @Flag(name: .customLong("hard"),
          help: "Move HEAD + reset index + reset working tree (destructive).")
    var hard: Bool = false

    @Argument(parsing: .captureForPassthrough,
              help: "Optional <commit> followed by `-- <paths>`.")
    var rest: [String] = []

    func validate() throws {
        let modeFlags = [soft, mixed, hard].filter { $0 }.count
        if modeFlags > 1 {
            throw ValidationError("--soft / --mixed / --hard are mutually exclusive")
        }
    }

    func run() async throws {
        let (commitArg, paths) = Self.split(rest)
        let target = commitArg ?? "HEAD"
        let client = CommandContext.gitClient()

        if !paths.isEmpty {
            // Per-path form. Mode flags don't apply here — real git
            // ignores them with a warning. We silently ignore to keep
            // exit codes clean.
            _ = try await client.reset(paths: paths, from: target)
            // Real git follows up with "Unstaged changes after reset:"
            // and the *full* unstaged status block (one `XY <path>` per
            // entry). Now that we have status, we can emit the right
            // thing instead of a hand-rolled stub.
            let report = try await client.status()
            let stderr = Stdio.stderr
            stderr.write(Data("Unstaged changes after reset:\n".utf8))
            for entry in report.unstagedEntries {
                let letter = entry.workdirState.letter
                stderr.write(Data("\(letter)\t\(entry.path)\n".utf8))
            }
            return
        }

        let mode: ResetMode = soft ? .soft : (hard ? .hard : .mixed)
        let outcome: ResetOutcome
        do {
            outcome = try await client.reset(to: target, mode: mode)
        } catch is Libgit2Error {
            // Real git distinguishes "unknown revision" from "not a path";
            // libgit2 lumps them. Emit the closer-to-real-git message.
            throw CLIError.stderr(
                "fatal: ambiguous argument '\(target)': unknown revision or path not in the working tree.",
                exitCode: 128)
        }

        // Output: silent for soft + mixed, summary line for hard.
        if case let .wholeTree(_, shortSHA, subject, mode) = outcome, mode == .hard {
            Stdio.print("HEAD is now at \(shortSHA) \(subject)")
        }
    }

    /// Split into (optional commit-ish, paths). With `--`, anything
    /// before is the commit and after is paths. Without `--`, all
    /// positionals collapse to the commit (single token) — real git's
    /// `<commit> <paths>` form requires the explicit separator.
    static func split(_ args: [String]) -> (commit: String?, paths: [String]) {
        if let sep = args.firstIndex(of: "--") {
            let pre = Array(args[..<sep])
            let post = Array(args[(sep + 1)...])
            return (pre.first, post)
        }
        return (args.first, [])
    }
}
