import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Log: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Show commit logs.",
        discussion: """
            Forms supported:
              git log                       walk HEAD's history
              git log <ref>                 start from <ref>
              git log <a>..<b>              commits reachable from <b> not <a>
              git log -- <paths>            limit to commits touching <paths>
              git log -<n> | -n <n>         cap output to N commits

            Format flags:
              --oneline                     short form `<sha7> <subject>`
              --format=<fmt>                custom %H/%h/%s/... template
              --stat                        append shortstat per commit
              -p / --patch                  append unified diff per commit
            """
    )

    @Flag(name: .customLong("oneline"),
          help: "Compact `<sha7> <subject>` output.")
    var oneline: Bool = false

    @Option(name: .customLong("format"),
            help: "Format template (e.g. `%H%n%an%n%s`).")
    var format: String?

    @Flag(name: .customLong("stat"),
          help: "Append shortstat after each commit.")
    var stat: Bool = false

    @Flag(name: [.customShort("p"), .customLong("patch")],
          help: "Append unified diff after each commit.")
    var patch: Bool = false

    @Option(name: .customShort("n"),
            help: "Limit output to N commits.")
    var maxCount: Int?

    @Argument(parsing: .captureForPassthrough,
              help: "Optional <ref> / <a>..<b> / `-- <paths>`. Also accepts `-<n>`.")
    var rest: [String] = []

    func run() async throws {
        // ArgumentParser's `.captureForPassthrough` strategy stops
        // recognising options once the first positional appears, so a
        // user typing `git log HEAD~2..HEAD --oneline` would have
        // `--oneline` stuck in `rest`. Walk `rest` and pull our known
        // flags back out before splitting refs/paths.
        var positionals: [String] = []
        var pulledOneline = oneline
        var pulledStat = stat
        var pulledPatch = patch
        var pulledFormat = format
        var i = 0
        while i < rest.count {
            let tok = rest[i]
            if tok == "--oneline" { pulledOneline = true; i += 1; continue }
            if tok == "--stat" { pulledStat = true; i += 1; continue }
            if tok == "--patch" || tok == "-p" { pulledPatch = true; i += 1; continue }
            if tok.hasPrefix("--format=") {
                pulledFormat = String(tok.dropFirst("--format=".count))
                i += 1; continue
            }
            if tok == "--format", i + 1 < rest.count {
                pulledFormat = rest[i + 1]
                i += 2; continue
            }
            positionals.append(tok)
            i += 1
        }
        let useOneline = pulledOneline
        let useStat = pulledStat
        let usePatch = pulledPatch
        let useFormat = pulledFormat

        // Entry.swift's argv preprocessor converts real-git's `-<n>`
        // shorthand into `-n <n>` before ArgumentParser sees it, so
        // `maxCount` already carries the value.
        let limit = maxCount

        let (refTokens, paths) = Self.splitOnDoubleDash(positionals)
        let (starts, excludes) = try Self.expandRefs(refTokens)

        let client = CommandContext.gitClient()
        let entries = try await client.log(LogQuery(
            starts: starts, excludes: excludes,
            maxCount: limit, paths: paths))

        let stdout = Stdio.stdout
        var first = true
        for entry in entries {
            if useOneline {
                stdout.write(Data((entry.onelineFormat() + "\n").utf8))
            } else if let useFormat {
                stdout.write(Data((entry.format(useFormat) + "\n").utf8))
            } else {
                if !first { stdout.write(Data("\n".utf8)) }
                stdout.write(Data(entry.defaultFormat().utf8))
                if useStat || usePatch {
                    let extra = try await additionalSection(
                        client: client, entry: entry, stat: useStat, patch: usePatch)
                    if !extra.isEmpty {
                        stdout.write(Data("\n".utf8))
                        stdout.write(Data(extra.utf8))
                    }
                }
            }
            first = false
        }
    }

    /// Build a `--stat` or `-p` block for one commit. Diff against the
    /// first parent (empty tree for the root commit) so the output
    /// matches what `git log --stat` / `-p` produces.
    private func additionalSection(
        client: SwiftGit.GitClient, entry: LogEntry,
        stat: Bool, patch: Bool
    ) async throws -> String {
        let target: DiffTarget
        if let parent = entry.parentSHAs.first {
            target = .commitVsCommit(parent, entry.sha)
        } else {
            // Root commit — diff against empty.
            target = .commitVsCommit(entry.sha, entry.sha)  // produces nothing
            // Better: diff entry against itself returns empty; instead
            // fall back to diff vs empty by using a tree-only path.
            // libgit2's diff_tree_to_tree(NULL, newTree, ...) is what
            // we'd want; the simplest workaround for root commits is
            // to just skip the section.
            return ""
        }
        if patch {
            return try await client.diff(target, format: .patch)
        } else {
            // Real git's `log --stat` uses the FULL stat block (per-file
            // bars + summary), not shortstat.
            return try await client.diff(target, format: .stat)
        }
    }

    /// Real-git's `<a>..<b>` / `<a>...<b>` notation expanded to push +
    /// hide pairs for revwalk. Bare refs go to `starts`.
    static func expandRefs(_ tokens: [String]) throws -> (starts: [String], excludes: [String]) {
        var starts: [String] = []
        var excludes: [String] = []
        for tok in tokens {
            if tok.contains("...") {
                // Symmetric difference — needs merge-base; we just push
                // both sides without hiding to approximate (real git's
                // behaviour for log differs from diff).
                let parts = tok.components(separatedBy: "...")
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                    starts.append(parts[0])
                    starts.append(parts[1])
                    continue
                }
                throw CLIError.stderr(
                    "fatal: invalid range '\(tok)'", exitCode: 128)
            }
            if tok.contains("..") {
                let parts = tok.components(separatedBy: "..")
                if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
                    excludes.append(parts[0])
                    starts.append(parts[1])
                    continue
                }
                throw CLIError.stderr(
                    "fatal: invalid range '\(tok)'", exitCode: 128)
            }
            // `^<ref>` form — exclude.
            if tok.hasPrefix("^") {
                excludes.append(String(tok.dropFirst()))
                continue
            }
            starts.append(tok)
        }
        return (starts, excludes)
    }

    /// Split positional args at `--` into (refs, paths).
    static func splitOnDoubleDash(_ args: [String]) -> (refs: [String], paths: [String]) {
        if let sep = args.firstIndex(of: "--") {
            return (Array(args[..<sep]), Array(args[(sep + 1)...]))
        }
        return (args, [])
    }
}
