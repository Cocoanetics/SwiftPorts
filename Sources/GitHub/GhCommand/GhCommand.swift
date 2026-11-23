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
        var args = args
        if let idx = args.firstIndex(of: "--json") {
            let next = idx + 1
            if next >= args.count || args[next].hasPrefix("-") {
                args.insert("", at: next)
            }
        }
        return preprocessReleaseEdit(args)
    }

    /// `gh release edit`'s `--draft`, `--prerelease`, `--latest` and
    /// `--verify-tag` are pflag bools: bare means true, `--draft=false`
    /// means false. ArgumentParser can't express that on one flag, so
    /// the bare spelling becomes `--draft=true` for an
    /// ``ReleaseEditBool`` option. Values of value-taking options and
    /// everything after `--` are left alone. A long option's attached
    /// value (`--notes=…`) is split into its own element, because
    /// ArgumentParser reads an empty `--notes=` as a bare `--notes`
    /// while pflag reads it as the empty string.
    static func preprocessReleaseEdit(_ args: [String]) -> [String] {
        guard args.count >= 2, args[0] == "release", args[1] == "edit" else { return args }
        let bools: Set<String> = ["--draft", "--prerelease", "--latest", "--verify-tag"]
        let valued: Set<String> = [
            "-R", "--repo", "-t", "--title", "-n", "--notes", "-F", "--notes-file",
            "--discussion-category", "--target", "--tag"
        ]
        var result = Array(args.prefix(2))
        var index = 2
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                result.append(contentsOf: args[index...])
                break
            }
            if bools.contains(arg) {
                result.append(arg + "=true")
            } else if arg.hasPrefix("--"), let equals = arg.firstIndex(of: "="),
                      valued.contains(String(arg[..<equals])) {
                result.append(contentsOf: [String(arg[..<equals]), String(arg[arg.index(after: equals)...])])
            } else if valued.contains(arg), index + 1 < args.count {
                result.append(contentsOf: [arg, args[index + 1]])
                index += 1
            } else {
                result.append(arg)
            }
            index += 1
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
