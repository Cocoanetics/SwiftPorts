import Foundation
import ArgumentParser
import GitCommand
import ShellKit

@main
struct Entry {
    static func main() async {
        do {
            // `Shell.arguments` already strips argv[0] (see
            // `Shell.processDefault` in ShellKit), so we hand it to
            // the preprocessor as-is. The earlier `dropFirst()` here
            // was a leftover from when this read `CommandLine.arguments`
            // directly; double-dropping made `git <subcommand>` (with
            // no extra args) silently print the root help.
            let argv = GitCommand.preprocess(Shell.arguments)
            var cmd = try GitCommand.parseAsRoot(argv)
            if var asyncCmd = cmd as? any AsyncParsableCommand {
                try await asyncCmd.run()
            } else {
                try cmd.run()
            }
        } catch let cli as CLIError {
            cli.emitAndExit()
        } catch {
            // Hand off to ArgumentParser's default formatter for usage
            // errors / validation failures; preserves help output etc.
            GitCommand.exit(withError: error)
        }
    }

}
