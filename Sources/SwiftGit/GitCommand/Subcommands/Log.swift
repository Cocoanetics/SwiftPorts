import ArgumentParser
import ShellKit
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
                                            (%G? %GS %GK %GF %GP %GT %GG
                                            from the commit's signature)
              --show-signature              check each signed commit's
                                            signature and show the result
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

    @Flag(name: .customLong("show-signature"), inversion: .prefixedNo,
          help: "Check signed commits' signatures and show the result (log.showSignature).")
    var showSignature: Bool?

    @Argument(parsing: .captureForPassthrough,
              help: "Optional <ref> / <a>..<b> / `-- <paths>`. Also accepts `-<n>`.")
    var rest: [String] = []

    func run() async throws {
        let pulled = Self.pullPassthrough(
            rest: rest,
            oneline: oneline, stat: stat, patch: patch,
            format: format, maxCount: maxCount)
        let useOneline = pulled.oneline
        let useStat = pulled.stat
        let usePatch = pulled.patch
        let useFormat = pulled.format
        let limit = pulled.maxCount

        let client = CommandContext.gitClient()
        let (showSignatures, positionals) = try await Self.pullShowSignature(
            pulled.positionals, flag: showSignature, client: client)
        let (refTokens, paths) = Self.splitOnDoubleDash(positionals)
        let (starts, excludes) = try Self.expandRefs(refTokens)
        let checksSignatures = showSignatures || useFormat.map(Self.usesSignature) == true
        let entries = try await client.log(LogQuery(
            starts: starts, excludes: excludes,
            maxCount: limit, paths: paths))

        let stdout = Shell.current.stdout
        var first = true
        for entry in entries {
            let check = checksSignatures ? try await client.commitSignatureCheck(entry.sha) : nil
            // git shows the signature after the `commit` line (with
            // `--oneline`, the abbreviated name), before the commit itself
            // with `--format`.
            let signature = showSignatures ? Self.signatureLines(check) : ""
            if useOneline {
                var line = entry.onelineFormat()
                if let space = line.firstIndex(of: " ") {
                    line.insert(contentsOf: signature, at: line.index(after: space))
                }
                stdout.write(Data((line + "\n").utf8))
            } else if let useFormat {
                stdout.write(Data((signature + Self.format(entry, useFormat, signature: check) + "\n").utf8))
            } else {
                if !first { stdout.write(Data("\n".utf8)) }
                var block = entry.defaultFormat()
                if let header = block.firstIndex(of: "\n") {
                    block.insert(contentsOf: signature, at: block.index(after: header))
                }
                stdout.write(Data(block.utf8))
            }
            // `--stat` and `-p` are independent of the format toggle —
            // real git happily renders `log --oneline --stat -1` as a
            // one-line subject followed by the per-file stat block.
            // Previously the stat/patch branch only fired in the
            // default-format arm of the if/else above, so combining
            // `--oneline` with `--stat` silently dropped the stat.
            if useStat || usePatch {
                let extra = try await additionalSection(
                    client: client, entry: entry, stat: useStat, patch: usePatch)
                if !extra.isEmpty {
                    stdout.write(Data("\n".utf8))
                    stdout.write(Data(extra.utf8))
                }
            }
            first = false
        }
    }

    /// Build a `--stat` or `-p` block for one commit. Diff against the
    /// first parent — or against the empty tree for the root commit,
    /// which real git renders as every file being added.
    private func additionalSection(
        client: SwiftGit.GitClient, entry: LogEntry,
        stat: Bool, patch: Bool
    ) async throws -> String {
        let target: DiffTarget
        if let parent = entry.parentSHAs.first {
            target = .commitVsCommit(parent, entry.sha)
        } else {
            target = .emptyVsCommit(entry.sha)
        }
        if patch {
            return try await client.diff(target, format: .patch)
        } else {
            // Real git's `log --stat` uses the FULL stat block (per-file
            // bars + summary), not shortstat.
            return try await client.diff(target, format: .stat)
        }
    }

    /// Outputs of `pullPassthrough` — the resolved flag values and the
    /// positional residue that remains to be split on `--` and parsed
    /// as refs / pathspecs.
    struct PullResult: Equatable {
        var oneline: Bool
        var stat: Bool
        var patch: Bool
        var format: String?
        var maxCount: Int?
        var positionals: [String]
    }

    /// ArgumentParser's `.captureForPassthrough` strategy stops
    /// recognising options once the first positional appears, so a
    /// user typing `git log HEAD~2..HEAD --oneline` ends up with
    /// `--oneline` stuck in `rest`. Walk `rest` and pull our known
    /// flags back out before splitting refs/paths.
    ///
    /// GitCommand's argv preprocessor converts real-git's `-<n>`
    /// shorthand into `-n <n>` before ArgumentParser sees it. When that
    /// shorthand appears after a revision, ArgumentParser leaves the
    /// normalized pair in `rest`, so pull both `-n <n>` and the raw
    /// `-<n>` form here.
    ///
    /// Real git stops interpreting flags at `--`; everything after is
    /// a pathspec. Mirror that so `git log -- -1` keeps `-1` as a path
    /// filter instead of being swallowed as `--max-count=1`.
    static func pullPassthrough(
        rest: [String],
        oneline: Bool, stat: Bool, patch: Bool,
        format: String?, maxCount: Int?
    ) -> PullResult {
        var result = PullResult(
            oneline: oneline, stat: stat, patch: patch,
            format: format, maxCount: maxCount, positionals: [])
        var seenDoubleDash = false
        var i = 0
        while i < rest.count {
            let tok = rest[i]
            if tok == "--" {
                seenDoubleDash = true
                result.positionals.append(tok)
                i += 1
                continue
            }
            if !seenDoubleDash {
                if tok == "--oneline" { result.oneline = true; i += 1; continue }
                if tok == "--stat" { result.stat = true; i += 1; continue }
                if tok == "--patch" || tok == "-p" { result.patch = true; i += 1; continue }
                if tok.hasPrefix("--format=") {
                    result.format = String(tok.dropFirst("--format=".count))
                    i += 1; continue
                }
                if tok == "--format", i + 1 < rest.count {
                    result.format = rest[i + 1]
                    i += 2; continue
                }
                if tok == "-n", i + 1 < rest.count,
                   let count = Int(rest[i + 1]) {
                    result.maxCount = count
                    i += 2
                    continue
                }
                if tok.count > 1, tok.hasPrefix("-"),
                   tok.dropFirst().allSatisfy(\.isNumber),
                   let count = Int(tok.dropFirst()) {
                    result.maxCount = count
                    i += 1
                    continue
                }
            }
            result.positionals.append(tok)
            i += 1
        }
        return result
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
