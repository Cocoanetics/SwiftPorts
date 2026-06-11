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
        return args
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
