import ArgumentParser
import ForgeKit
import Foundation
import ShellKit
import SwiftGit

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Show changes between commits, commit and working tree, etc.",
        discussion: """
            Supported invocations:
              git diff                        working tree vs index
              git diff --cached               index vs HEAD
              git diff <ref>                  working tree vs <ref>
              git diff <ref-a> <ref-b>        between two commit-ishes
              git diff <a>..<b>               same as `<a> <b>`
              git diff <a>...<b>              `<merge-base(a,b)> <b>`

            Append `-- <paths>...` to filter explicitly. Without `--`,
            arguments are tried as refs first; non-resolvable args that
            exist on disk are treated as pathspecs.

            Format flags: `--stat`, `--shortstat`, `--numstat`, `--raw`,
            `--name-only`, `--name-status`. Default is unified patch
            (`-p` / `--patch`). Use `-U<n>` / `--unified <n>` to control
            context lines.
            """
    )

    @Flag(name: [.customLong("cached"), .customLong("staged")],
          help: "Show staged (index vs HEAD) instead of unstaged.")
    var cached: Bool = false

    @Flag(name: [.customShort("p"), .customLong("patch")],
          help: "Force patch output (the default).")
    var patch: Bool = false

    @Flag(name: .customLong("stat"),
          help: "Show stat-style summary instead of unified diff.")
    var stat: Bool = false

    @Flag(name: .customLong("shortstat"),
          help: "Just the summary line of `--stat`.")
    var shortStat: Bool = false

    @Flag(name: .customLong("numstat"),
          help: "Machine-readable stat: insertions, deletions, path.")
    var numStat: Bool = false

    @Flag(name: .customLong("raw"),
          help: "Raw `:<modes> <oldsha> <newsha> <status>\\t<path>` output.")
    var raw: Bool = false

    @Flag(name: .customLong("name-only"),
          help: "Show only the names of changed files.")
    var nameOnly: Bool = false

    @Flag(name: .customLong("name-status"),
          help: "Show names + change status (M/A/D/R) of changed files.")
    var nameStatus: Bool = false

    @Option(name: [.customShort("U"), .customLong("unified")],
            help: "Number of context lines (default 3).")
    var unified: Int?

    @Option(name: .customLong("color"),
            help: "Colorize patch output: always, auto (default), or never.")
    var color: ColorChoice = .auto

    @Argument(parsing: .captureForPassthrough,
              help: "Optional commit-ishes / range / `-- <paths>`.")
    var rest: [String] = []

    func run() async throws {
        let format = try resolveFormat()

        // Step 1 — split out paths after `--` if present. Anything
        // before `--` is candidate refs to be resolved against libgit2.
        let (refCandidates, explicitPaths) = Self.splitOnDoubleDash(rest)

        // Step 2 — preprocess range notation. `a..b` and `a...b` each
        // explode into two refs (with a flag for the symmetric case).
        let (refs, isSymmetric) = try Self.expandRanges(refCandidates)

        let client = CommandContext.gitClient()

        // Step 3 — smart ref/path disambiguation when `--` was absent.
        // A token that doesn't resolve as a ref but exists on disk
        // (or matches a glob) is treated as a pathspec.
        var trueRefs: [String] = []
        var derivedPaths: [String] = []
        if explicitPaths.isEmpty {
            for token in refs {
                if try await client.canResolveRef(token) {
                    trueRefs.append(token)
                } else if Self.looksLikePath(token) {
                    derivedPaths.append(token)
                } else {
                    throw CLIError.stderr(
                        "fatal: ambiguous argument '\(token)': unknown revision or path not in the working tree.",
                        exitCode: 128)
                }
            }
        } else {
            trueRefs = refs
        }
        let paths = explicitPaths.isEmpty ? derivedPaths : explicitPaths

        // Step 4 — resolve to a DiffTarget.
        let target: DiffTarget
        switch trueRefs.count {
        case 0:
            target = cached ? .indexVsHead : .workdirVsIndex
        case 1:
            if cached {
                throw CLIError.stderr(
                    "fatal: --cached takes no commit arguments", exitCode: 128)
            }
            target = .workdirVsCommit(trueRefs[0])
        case 2:
            if cached {
                throw CLIError.stderr(
                    "fatal: --cached takes no commit arguments", exitCode: 128)
            }
            if isSymmetric {
                let mergeBase = try await client.mergeBase(trueRefs[0], trueRefs[1])
                target = .commitVsCommit(mergeBase, trueRefs[1])
            } else {
                target = .commitVsCommit(trueRefs[0], trueRefs[1])
            }
        default:
            throw CLIError.stderr(
                "fatal: too many commit-ishes (max 2): \(trueRefs.joined(separator: " "))",
                exitCode: 128)
        }

        // Step 5 — run the diff.
        let context = unified.map { UInt32(max(0, $0)) }
        var output = try await client.diff(
            target, format: format, paths: paths, contextLines: context)
        // Colorize the human-readable forms the way real git does — the
        // unified patch and the `--stat` histogram. `--shortstat` (which
        // real git leaves plain) and the machine-readable formats
        // (`--raw`, `--name-only`, `--name-status`, `--numstat`) stay
        // uncolored so downstream pipes don't have to strip escapes.
        if !output.isEmpty {
            switch format {
            case .patch:
                output = ColorPalette(enabled: color.resolved()).colorizePatch(output)
            case .stat:
                output = ColorPalette(enabled: color.resolved()).colorizeDiffStat(output)
            default:
                break
            }
        }
        if !output.isEmpty {
            Shell.current.stdout.write(Data(output.utf8))
        }
    }

    private func resolveFormat() throws -> DiffFormat {
        // Flag count guard — real git accepts only one output mode at a
        // time. Anything more would be ambiguous.
        let modes = [stat, shortStat, numStat, raw, nameOnly, nameStatus, patch]
        let count = modes.filter { $0 }.count
        if count > 1 {
            throw CLIError.stderr(
                "fatal: only one of --stat / --shortstat / --numstat / --raw / --name-only / --name-status / --patch may be set",
                exitCode: 128)
        }
        if stat { return .stat }
        if shortStat { return .shortStat }
        if numStat { return .numStat }
        if raw { return .raw }
        if nameStatus { return .nameStatus }
        if nameOnly { return .nameOnly }
        return .patch
    }

    /// Split `args` at the first `--` separator. Tokens before are ref
    /// candidates; tokens after are explicit pathspecs.
    static func splitOnDoubleDash(_ args: [String]) -> (refs: [String], paths: [String]) {
        if let sep = args.firstIndex(of: "--") {
            return (Array(args[..<sep]), Array(args[(sep + 1)...]))
        }
        return (args, [])
    }

    /// Convert `a..b` and `a...b` tokens into individual refs. Returns
    /// the second flag set to `true` when the source used `...` so the
    /// caller can replace `a` with the merge-base of the two.
    /// Throws if multiple range tokens are given (real git's behaviour).
    static func expandRanges(_ tokens: [String]) throws -> (refs: [String], isSymmetric: Bool) {
        var refs: [String] = []
        var symmetric = false
        var sawRange = false
        for tok in tokens {
            if tok.contains("...") {
                if sawRange {
                    throw CLIError.stderr(
                        "fatal: more than one range supplied", exitCode: 128)
                }
                let parts = tok.components(separatedBy: "...")
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    throw CLIError.stderr(
                        "fatal: invalid range '\(tok)'", exitCode: 128)
                }
                refs.append(contentsOf: parts)
                symmetric = true
                sawRange = true
            } else if tok.contains("..") {
                if sawRange {
                    throw CLIError.stderr(
                        "fatal: more than one range supplied", exitCode: 128)
                }
                let parts = tok.components(separatedBy: "..")
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                    throw CLIError.stderr(
                        "fatal: invalid range '\(tok)'", exitCode: 128)
                }
                refs.append(contentsOf: parts)
                sawRange = true
            } else {
                refs.append(tok)
            }
        }
        return (refs, symmetric)
    }

    /// Heuristic for the no-`--` case: real git treats unresolvable
    /// arguments as paths if they exist on disk (or look like
    /// pathspec globs). We mirror that test against the cwd.
    static func looksLikePath(_ token: String) -> Bool {
        if token.contains("/") || token.contains("*") || token.contains("?") {
            return true
        }
        let resolved = Shell.currentDirectory
            .appendingPathComponent(token).path
        return FileManager.default.fileExists(atPath: resolved)
    }

    // Kept for source compatibility with the previous parsing tests —
    // identical to ``splitOnDoubleDash``.
    static func split(_ args: [String]) throws -> (refs: [String], paths: [String]) {
        splitOnDoubleDash(args)
    }
}
