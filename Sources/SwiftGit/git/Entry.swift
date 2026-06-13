import Foundation
import ArgumentParser
import GitCommand
import ShellKit

@main
struct Entry {
    static func main() async {
        do {
            // Real git accepts attached short-option-with-value forms
            // like `-U3` (= `-U 3`). ArgumentParser doesn't support
            // those for typed options, so split them out before parsing.
            //
            // `Shell.arguments` already strips argv[0] (see
            // `Shell.processDefault` in ShellKit), so we hand it to
            // the preprocessor as-is. The earlier `dropFirst()` here
            // was a leftover from when this read `CommandLine.arguments`
            // directly; double-dropping made `git <subcommand>` (with
            // no extra args) silently print the root help.
            // `Self.preprocess` splits git's attached short-option forms
            // (`-U3`, log `-1`); `GitCommand.preprocess` normalises a bare
            // `--color` into `--color=always`. The latter is shared with
            // the embedded shellkit face so both git entry points agree.
            let argv = GitCommand.preprocess(Self.preprocess(Shell.arguments))
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

    /// Split git's attached short-option-with-value forms into separate
    /// tokens so ArgumentParser can parse them.
    /// - `-U<n>` → `-U <n>` (diff context lines)
    /// - `-<n>` → `-n <n>` (log count limit) — only for the `log`
    ///   subcommand, since `-1` etc. aren't generic git shorthand.
    static func preprocess(_ args: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(args.count)
        let isLog = args.first == "log"
        for arg in args {
            if arg.count > 2, arg.hasPrefix("-U"),
               arg.dropFirst(2).allSatisfy(\.isNumber) {
                out.append("-U")
                out.append(String(arg.dropFirst(2)))
                continue
            }
            // For `git log`, accept real-git's `-<n>` shorthand as
            // `-n <n>`. Don't apply globally — `-1` could be a valid
            // negative-int positional in another subcommand.
            if isLog, arg.count > 1, arg.hasPrefix("-"),
               arg.dropFirst().allSatisfy(\.isNumber) {
                out.append("-n")
                out.append(String(arg.dropFirst()))
                continue
            }
            out.append(arg)
        }
        return out
    }
}
