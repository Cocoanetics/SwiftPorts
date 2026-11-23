import ArgumentParser
import ShellKit

public struct GlabCommand: AsyncParsableCommand {
    /// Argv rewrites shared by the standalone entry (``main()``) and the
    /// shellkit-bridge wrapper in `SwiftPortsCommands`, for the pflag
    /// forms of `glab release create` that ArgumentParser can't parse:
    /// - `--no-update` is a pflag bool: bare means true and
    ///   `--no-update=false` means false. The bare spelling becomes
    ///   `--no-update=true` for a ``ReleaseCreateBool``.
    /// - A string option takes its value verbatim, whatever it looks
    ///   like (`- Fixed`, `---`, `--`), separate (`-N x`), joined
    ///   (`-Nx`, `-N=x`) or attached (`--notes=x`). Each becomes
    ///   `--notes=x`, so the value can't be read as an option or
    ///   terminator, or `--notes ""` when empty, because ArgumentParser
    ///   reads an empty `--notes=` as a bare `--notes`.
    /// Everything after `--` is left alone.
    public static func preprocess(_ args: [String]) -> [String] {
        guard args.count >= 2, args[0] == "release", args[1] == "create" else { return args }
        return Array(args.prefix(2)) + normalizePflagArgs(
            Array(args.dropFirst(2)),
            bools: ["--no-update"],
            shorts: ["R": "--repo", "n": "--name", "r": "--ref", "N": "--notes", "F": "--notes-file"],
            longs: ["--repo", "--name", "--ref", "--notes", "--notes-file"])
    }

    /// Canonicalize pflag bool and string options; see ``preprocess(_:)``.
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
                if let equals = arg.firstIndex(of: "="), bools.contains(String(arg[..<equals])),
                   arg.index(after: equals) == arg.endIndex {
                    // An empty bool (`--draft=`) must fail like pflag's
                    // ParseBool(""); left attached, ArgumentParser would
                    // drop the `=` and take the next word as the value.
                    result += [String(arg[..<equals]), ""]
                } else if let equals = arg.firstIndex(of: "="), longs.contains(String(arg[..<equals])) {
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
                // pflag shorthand: `-N x`, `-Nx`, or `-N=x`.
                // pflag strips the `=` only when a value follows it, so
                // `-N=` carries the literal value "=".
                var joined = String(arg.dropFirst(2))
                if joined.hasPrefix("="), joined.count > 1 { joined.removeFirst() }
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
    /// ``preprocess(_:)``.
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
        commandName: "glab",
        abstract: "Work seamlessly with GitLab from the command line.",
        version: "0.1.0-dev",
        subcommands: [
            VersionCommand.self,
            ApiCommand.self,
            AuthCommand.self,
            IssueCommand.self,
            MrCommand.self,
            CiCommand.self,
            RepoCommand.self,
            ReleaseCommand.self,
            TagCommand.self,
            VariableCommand.self,
            LabelCommand.self,
        ]
    )

    public init() {}
}
