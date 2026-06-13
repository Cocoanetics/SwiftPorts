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
        ]
    )

    /// Rewrite a bare `--color` (the exact token, no `=<when>`) into
    /// `--color=always` for the `diff` / `status` subcommands — the two
    /// that bind a `--color` option. Real git documents `--color[=<when>]`
    /// where omitting `<when>` means `always`, and only attaches the value
    /// with `=` — so `git diff --color <ref>` keeps `<ref>` as a revision
    /// and never swallows it as the color value. swift-argument-parser's
    /// `@Option` can't express an optional, attached-only value, so we
    /// normalise the bare form here, before parsing.
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
        // Only `diff` / `status` define `--color`; leave every other
        // subcommand's argv exactly as given.
        guard let subcommand = args.first,
              subcommand == "diff" || subcommand == "status" else {
            return args
        }
        var out: [String] = []
        out.reserveCapacity(args.count)
        var afterDoubleDash = false
        for arg in args {
            if arg == "--" { afterDoubleDash = true }
            if !afterDoubleDash, arg == "--color" {
                out.append("--color=always")
            } else {
                out.append(arg)
            }
        }
        return out
    }

    public init() {}
}
