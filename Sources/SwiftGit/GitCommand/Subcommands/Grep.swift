import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

/// `git grep PATTERN [-- PATHS...]` — search tracked files for lines
/// matching `PATTERN`. Output shape mirrors real git's:
///
///   <path>            with `-l`
///   <path>:<count>    with `-c`
///   <path>:<line>     default
///   <path>:<n>:<line> with `-n`
///
/// `.gitignore`'d paths are skipped automatically — they aren't in the
/// index. Use `--untracked` to extend the search to untracked-but-not-
/// ignored files (matches real `git grep --untracked`).
struct Grep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grep",
        abstract: "Print lines matching a pattern in tracked files."
    )

    @Argument(help: "Pattern (regex; NSRegularExpression syntax).")
    var pattern: String

    @Argument(help: "Pathspecs / globs to limit the search.")
    var paths: [String] = []

    @Flag(name: [.customShort("i"), .customLong("ignore-case")],
          help: "Case-insensitive match.")
    var ignoreCase: Bool = false

    @Flag(name: [.customShort("n"), .customLong("line-number")],
          help: "Prefix each match with its 1-indexed line number.")
    var lineNumber: Bool = false

    @Flag(name: [.customShort("l"), .customLong("name-only")],
          help: "Print only the paths of matching files.")
    var nameOnly: Bool = false

    @Flag(name: [.customShort("c"), .customLong("count")],
          help: "Print only the per-file count of matches.")
    var count: Bool = false

    @Flag(name: .customLong("untracked"),
          help: "Also search untracked files that aren't gitignored.")
    var untracked: Bool = false

    @Flag(name: [.customShort("E"), .customLong("extended-regexp")],
          help: "Accepted for parity — patterns are always NSRegularExpression.")
    var extendedRegexp: Bool = false

    func run() async throws {
        // `-E` is a no-op for us; we always interpret PATTERN through
        // `NSRegularExpression`, which is a superset of POSIX ERE.
        _ = extendedRegexp

        let client = CommandContext.gitClient()
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }

        let matches: [GrepMatch]
        do {
            matches = try await client.grep(
                pattern: pattern,
                options: options,
                pathFilters: paths,
                includeUntracked: untracked)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain {
            throw CLIError.stderr(
                "fatal: invalid regex pattern '\(pattern)': \(error.localizedDescription)",
                exitCode: 128)
        }

        let stdout = Shell.current.stdout
        if nameOnly {
            var seen = Set<String>()
            for match in matches where seen.insert(match.path).inserted {
                stdout.write(Data((match.path + "\n").utf8))
            }
        } else if count {
            let groups = Dictionary(grouping: matches, by: \.path)
            for path in groups.keys.sorted() {
                let n = groups[path]?.count ?? 0
                stdout.write(Data("\(path):\(n)\n".utf8))
            }
        } else {
            for match in matches {
                let body = lineNumber
                    ? "\(match.path):\(match.lineNumber):\(match.line)"
                    : "\(match.path):\(match.line)"
                stdout.write(Data((body + "\n").utf8))
            }
        }

        // Real git grep exits 1 when no matches; subcommand callers
        // chained behind `&&` rely on this to skip the rest of the
        // pipeline.
        if matches.isEmpty {
            throw ExitCode(1)
        }
    }
}
