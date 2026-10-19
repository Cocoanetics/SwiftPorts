import ArgumentParser
import ShellKit
import Foundation
import SwiftGit

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read or write repository / user / system configuration values."
    )

    @Flag(name: .customLong("global"),
          help: "Operate on `~/.gitconfig` instead of `.git/config`.")
    var global: Bool = false

    @Flag(name: .customLong("system"),
          help: "Operate on the system `gitconfig` (read-only).")
    var system: Bool = false

    @Flag(name: .customLong("local"),
          help: "Operate on the repo's `.git/config` (the default).")
    var local: Bool = false

    @Flag(name: .customLong("get"),
          help: "Print the value for <name>.")
    var get: Bool = false

    @Flag(name: .customLong("unset"),
          help: "Remove the <name> entry.")
    var unset: Bool = false

    @Flag(name: [.customShort("l"), .customLong("list")],
          help: "List every configured key/value.")
    var list: Bool = false

    @Argument(help: "Config key (e.g. `user.email`) and optional value.")
    var args: [String] = []

    private var scope: ConfigScope {
        if global { return .global }
        if system { return .system }
        return .local
    }

    /// git's "bad config line 3 in file <path>" for libgit2's "failed to
    /// parse config file: <why> (in <path>:3)", else nil.
    static func badConfigLine(in message: String) -> String? {
        guard message.hasPrefix("failed to parse config file:"),
              let regex = try? NSRegularExpression(pattern: #"\(in (.+):(\d+)(?:, column \d+)?\)$"#),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let path = Range(match.range(at: 1), in: message),
              let line = Range(match.range(at: 2), in: message)
        else { return nil }
        return "bad config line \(message[line]) in file \(message[path])"
    }

    /// Whether this call changes the config.
    private var writes: Bool {
        unset || (!list && !get && args.count == 2)
    }

    /// A read without a scope flag sees every level, as git's does.
    private var readScope: ConfigScope? {
        global || system || local ? scope : nil
    }

    func run() async throws {
        do {
            try await configure()
        } catch let error as Libgit2Error {
            throw translated(error) ?? error
        }
    }

    /// git's wording and exit status for a libgit2 failure, else nil.
    private func translated(_ error: Libgit2Error) -> CLIError? {
        let message = error.message
        if let line = Self.badConfigLine(in: message) {
            return CLIError.stderr("fatal: \(line)", exitCode: 128)
        }
        if message.hasPrefix("unable to read config file") {
            return CLIError.stderr("fatal: \(message)", exitCode: 128)
        }
        if message.contains("not unique") && (unset || args.count == 2) {
            // More than one line has the key: git changes nothing.
            let key = args.first ?? ""
            var lines = ["warning: \(key) has multiple values"]
            if !unset {
                lines += ["error: cannot overwrite multiple values with a single value",
                          "       Use a regexp, --add or --replace-all to change \(key)."]
            }
            return CLIError.stderr(lines, exitCode: 5)
        }
        if message.hasPrefix("unable to access") { return unreadable(message) }
        if message.hasPrefix("could not lock config file") {
            return CLIError.stderr("error: \(message)", exitCode: 255)
        }
        if message.hasPrefix("could not write config file") {
            // A selected file that is no file (`GIT_CONFIG_GLOBAL=`).
            return CLIError.stderr("error: \(message)", exitCode: 4)
        }
        if message.contains("Permission denied") && scope != .local { return permissionDenied() }
        if GitClient.isNoRepository(error) {
            // `--local`, or a write with no scope, needs a repository.
            return CLIError.stderr(
                local ? "fatal: --local can only be used inside a git repository"
                      : "fatal: not in a git directory",
                exitCode: 128)
        }
        return nil
    }

    /// An existing file that can't be read: git warns, then a change
    /// can't open it, a list is fatal, and a get finds nothing.
    private func unreadable(_ message: String) -> CLIError {
        if writes {
            let file = GitClient.configFile(for: scope)
            return CLIError.stderr(
                ["warning: \(message)", "error: opening \(file): Permission denied"], exitCode: 3)
        }
        if list { return CLIError.stderr("fatal: \(message)", exitCode: 128) }
        Shell.current.stderr("warning: \(message)\n")
        return CLIError(lines: [], exitCode: 1)
    }

    /// The scope's file can't be written or read, as git words it.
    private func permissionDenied() -> CLIError {
        let file = GitClient.configFile(for: scope)
        if writes {
            return CLIError.stderr("error: could not lock config file \(file): Permission denied", exitCode: 255)
        }
        return CLIError.stderr("fatal: unable to access '\(file)': Permission denied", exitCode: 128)
    }

    /// `--get <name> <value-pattern>`: the value if it matches, else status 1;
    /// a key that isn't there is status 1 whatever the pattern, and a pattern
    /// that isn't one is status 6.
    private func printValue(of name: String, matching pattern: String, with client: GitClient) async throws {
        guard let found = try await client.configGet(name, scope: readScope) else {
            throw CLIError(lines: [], exitCode: 1)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw CLIError.stderr("error: invalid pattern: \(pattern)", exitCode: 6)
        }
        guard regex.firstMatch(in: found, range: NSRange(found.startIndex..., in: found)) != nil else {
            throw CLIError(lines: [], exitCode: 1)
        }
        Shell.print(found)
    }

    private func configure() async throws {
        let client = CommandContext.gitClient()

        if list {
            for line in try await client.configLines(scope: readScope) {
                Shell.print(line)
            }
            return
        }

        if unset {
            guard let name = args.first else {
                throw CLIError.stderr(
                    "fatal: --unset requires a key", exitCode: 128)
            }
            // Like git, a key that wasn't there is exit status 5.
            guard try await client.configUnset(name, scope: scope) else {
                throw CLIError(lines: [], exitCode: 5)
            }
            return
        }

        // `--get <name> <value-pattern>` reads; it is never a set.
        if get && args.count == 2 {
            try await printValue(of: args[0], matching: args[1], with: client)
            return
        }

        switch args.count {
        case 1:
            // Read form: `git config <name>` or `git config --get <name>`.
            let name = args[0]
            if let value = try await client.configGet(name, scope: readScope) {
                Shell.print(value)
            } else {
                throw CLIError(lines: [], exitCode: 1)
            }
            _ = get  // explicit flag is fine but doesn't change behaviour
        case 2:
            // Write form: `git config <name> <value>`.
            try await client.configSet(args[0], args[1], scope: scope)
        default:
            throw CLIError.stderr(
                "fatal: usage: git config [--global|--system] <name> [<value>]",
                exitCode: 128)
        }
    }
}
