import ArgumentParser

public struct GitCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "git",
        abstract: "Pure-Swift git client backed by libgit2.",
        discussion: """
            A focused subset of the git CLI implemented on top of the
            in-process libgit2 build — no `git` binary required.

            Today's surface mirrors the `GitClient` protocol: clone,
            fetch, checkout, push, plus `remote` and `branch` reads.
            Useful as a SwiftBash builtin, in sandboxed embedders, and
            anywhere you'd otherwise shell out to `git`.
            """,
        version: "0.1.0-dev",
        subcommands: [
            VersionCommand.self,
            GitInit.self,
            Clone.self,
            Fetch.self,
            Pull.self,
            Checkout.self,
            Push.self,
            Add.self,
            Reset.self,
            Status.self,
            Commit.self,
            Merge.self,
            Rebase.self,
            CherryPick.self,
            Diff.self,
            Log.self,
            StashCommand.self,
            RemoteCommand.self,
            Branch.self,
            Tag.self,
            RevParse.self,
            Show.self,
            Mv.self,
            Rm.self,
            Config.self,
            Switch.self,
            Restore.self,
            LsFiles.self,
            Grep.self,
            Clean.self,
            Blame.self,
            Apply.self,
            Reflog.self,
            Describe.self,
            LsTree.self,
            CatFile.self,
            Archive.self,
            WorktreeCommand.self,
        ]
    )

    /// Normalize real-git argv shorthands before ArgumentParser sees them.
    ///
    /// - Bare `--color` becomes `--color=always` for `diff` / `status`.
    ///   Real git documents `--color[=<when>]` where omitting `<when>`
    ///   means `always`, and only attaches the value with `=`.
    /// - `-U<n>` becomes `-U <n>` for `diff`.
    /// - `-<n>` becomes `-n <n>` for `log`.
    ///
    /// Tokens after a standalone `--` are pathspecs and pass through
    /// untouched, so `git diff -- --color` still filters a file literally
    /// named `--color`.
    ///
    /// Shared by every entry path: the standalone binary (`Entry`) and the
    /// embedded shellkit face (`SwiftPortsCommands`). Embedded git never
    /// runs the binary's entry point, so a rewrite living only there would
    /// leave the two faces disagreeing (same rationale as gh's bare-`--json`
    /// rewrite).
    public static func preprocess(_ args: [String]) -> [String] {
        guard let subcommand = args.first else {
            return args
        }
        var out: [String] = []
        out.reserveCapacity(args.count)
        var afterDoubleDash = false
        for arg in args {
            if arg == "--" { afterDoubleDash = true }
            if !afterDoubleDash, (subcommand == "diff" || subcommand == "status"),
               arg == "--color" {
                out.append("--color=always")
            } else if !afterDoubleDash, subcommand == "diff",
                      arg.count > 2, arg.hasPrefix("-U"),
                      arg.dropFirst(2).allSatisfy(\.isNumber) {
                out.append("-U")
                out.append(String(arg.dropFirst(2)))
            } else if !afterDoubleDash, subcommand == "log",
                      arg.count > 1, arg.hasPrefix("-"),
                      arg.dropFirst().allSatisfy(\.isNumber) {
                out.append("-n")
                out.append(String(arg.dropFirst()))
            } else {
                out.append(arg)
            }
        }
        return out
    }

    public init() {}
}
