import ArgumentParser
import Foundation
import ShellKit

public struct GhCommand: AsyncParsableCommand {
    /// Rewrite bare `--json` (no value, or followed by another flag)
    /// into `--json ""`. Subcommands detect the empty value and print
    /// the available-fields list, the way upstream `gh` does.
    ///
    /// Shared by every entry path: ``main()`` below (the standalone
    /// binary) and the shellkit-bridge wrapper in `SwiftPortsCommands`
    /// — embedded gh never runs `main()`, so a rewrite living only
    /// here would leave the two faces disagreeing (issue #69).
    public static func preprocess(_ args: [String]) -> [String] {
        // `release edit` has no --json; its string options may carry a
        // literal `--json` value, so it gets only its own normalization.
        if args.count >= 2, args[0] == "release", args[1] == "edit" {
            return preprocessReleaseEdit(args)
        }
        var args = args
        if let idx = args.firstIndex(of: "--json") {
            let next = idx + 1
            if next >= args.count || args[next].hasPrefix("-") {
                args.insert("", at: next)
            }
        }
        return args
    }

    /// pflag-style argv for `gh release edit`, which ArgumentParser
    /// can't parse as-is:
    /// - `--draft`, `--prerelease`, `--latest` and `--verify-tag` are
    ///   pflag bools: bare means true, `--draft=false` means false. The
    ///   bare spelling becomes `--draft=true` for a ``ReleaseEditBool``.
    /// - A string option takes its value verbatim, whatever it looks
    ///   like (`---`, `--`, `--json`), separate (`-n x`), joined
    ///   (`-nx`, `-n=x`) or attached (`--notes=x`). Each becomes
    ///   `--notes=x`, so the value can't be read as an option or
    ///   terminator, or `--notes ""` when empty, because ArgumentParser
    ///   reads an empty `--notes=` as a bare `--notes`.
    /// Everything after `--` is left alone.
    static func preprocessReleaseEdit(_ args: [String]) -> [String] {
        guard args.count >= 2, args[0] == "release", args[1] == "edit" else { return args }
        return Array(args.prefix(2)) + normalizePflagArgs(
            Array(args.dropFirst(2)),
            bools: ["--draft", "--prerelease", "--latest", "--verify-tag"],
            shorts: ["R": "--repo", "t": "--title", "n": "--notes", "F": "--notes-file"],
            longs: ["--repo", "--title", "--notes", "--notes-file", "--discussion-category", "--target", "--tag"])
    }

    /// Canonicalize pflag bool and string options; see
    /// ``preprocessReleaseEdit(_:)``.
    static func normalizePflagArgs(
        _ args: [String],
        bools: Set<String>,
        shorts: [Character: String],
        longs: Set<String>
    ) -> [String] {
        func valued(_ long: String, _ value: String) -> [String] {
            value.isEmpty ? [long, ""] : ["\(long)=\(value)"]
        }
        var result: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if arg == "--" {
                result.append(contentsOf: args[(index - 1)...])
                break
            }
            if bools.contains(arg) {
                result.append(arg + "=true")
                continue
            }
            if arg.hasPrefix("--") {
                if let equals = arg.firstIndex(of: "="), longs.contains(String(arg[..<equals])) {
                    result += valued(String(arg[..<equals]), String(arg[arg.index(after: equals)...]))
                } else if longs.contains(arg), index < args.count {
                    result += valued(arg, args[index])
                    index += 1
                } else {
                    result.append(arg)
                }
                continue
            }
            if arg.count >= 2, arg.first == "-", let long = shorts[arg[arg.index(after: arg.startIndex)]] {
                // pflag shorthand: `-n x`, `-nx`, or `-n=x`.
                var joined = String(arg.dropFirst(2))
                if joined.hasPrefix("=") { joined.removeFirst() }
                if arg.count > 2 {
                    result += valued(long, joined)
                } else if index < args.count {
                    result += valued(long, args[index])
                    index += 1
                } else {
                    result.append(arg)
                }
                continue
            }
            result.append(arg)
        }
        return result
    }

    /// Custom entry point so the standalone binary applies
    /// ``preprocess(_:)``. `Shell.arguments` follows `$@` semantics —
    /// the program name is already excluded — so it's handed to the
    /// parser as-is. (An earlier `dropFirst()` here ate the first
    /// real argument and left the binary unable to parse any
    /// invocation: issue #69.)
    public static func main() async {
        let args = preprocess(Shell.arguments)
        do {
            var command = try parseAsRoot(args)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    public static let configuration = CommandConfiguration(
        commandName: "gh",
        abstract: "Work seamlessly with GitHub from the command line.",
        version: "0.1.0-dev",
        subcommands: [
            VersionCommand.self,
            AuthCommand.self,
            ApiCommand.self,
            RepoCommand.self,
            ReleaseCommand.self,
            IssueCommand.self,
            PrCommand.self,
            SearchCommand.self,
            GistCommand.self,
            WorkflowCommand.self,
            RunCommand.self,
            LabelCommand.self,
            ConfigCommand.self,
            ProjectCommand.self,
            BrowseCommand.self,
            SshKeyCommand.self,
            GpgKeyCommand.self,
            OrgCommand.self,
            VariableCommand.self,
            CacheCommand.self,
            SecretCommand.self,
        ]
    )

    public init() {}
}
