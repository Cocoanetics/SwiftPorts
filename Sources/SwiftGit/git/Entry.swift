import Foundation
import ArgumentParser
import GitCommand
import GitKitSSH
import ShellKit

@main
struct Entry {
    /// Opt-in env var (issue #113 Codex review): `GitKitSSH` only
    /// supports unencrypted ed25519/ECDSA identities and has no
    /// interactive `StrictHostKeyChecking ask` prompt, so it can't yet
    /// replace libgit2's `ssh_exec` fallback as the interactive CLI
    /// default — that needs ssh-agent/RSA/encrypted-key support and the
    /// first-connect prompt from Phase 3 (#115). Until then, interactive
    /// use of this `git` executable keeps `ssh_exec` (agent, RSA,
    /// encrypted keys, the known-hosts prompt all keep working); a
    /// non-interactive host that already controls its own known_hosts
    /// and identities (MissionControl, CI) opts in with
    /// `SWIFTPORTS_GIT_INPROCESS_SSH=1`.
    private static let inProcessSSHEnvVar = "SWIFTPORTS_GIT_INPROCESS_SSH"

    static func main() async {
        do {
            if ProcessInfo.processInfo.environment[inProcessSSHEnvVar] == "1" {
                try GitKitSSH.install()
            }
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
