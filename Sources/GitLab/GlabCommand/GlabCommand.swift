import ArgumentParser
import ShellKit

public struct GlabCommand: AsyncParsableCommand {
    /// Argv rewrites shared by the standalone entry (``main()``) and the
    /// shellkit-bridge wrapper in `SwiftPortsCommands`.
    ///
    /// `glab release create --no-update` is a pflag bool: bare means
    /// true and `--no-update=false` means false. ArgumentParser can't
    /// express that on one flag, so the bare spelling becomes
    /// `--no-update=true` for a ``ReleaseCreateBool`` option. Values of
    /// value-taking options and everything after `--` are left alone.
    public static func preprocess(_ args: [String]) -> [String] {
        guard args.count >= 2, args[0] == "release", args[1] == "create" else { return args }
        let valued: Set<String> = [
            "-R", "--repo", "-n", "--name", "-r", "--ref", "-N", "--notes", "-F", "--notes-file"
        ]
        var result = Array(args.prefix(2))
        var index = 2
        while index < args.count {
            let arg = args[index]
            if arg == "--" {
                result.append(contentsOf: args[index...])
                break
            }
            if arg == "--no-update" {
                result.append("--no-update=true")
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
