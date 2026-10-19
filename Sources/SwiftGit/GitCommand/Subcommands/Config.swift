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

    /// Whether this call changes the config.
    private var writes: Bool {
        unset || (!list && args.count == 2)
    }

    /// A read without a scope flag sees every level, as git's does.
    private var readScope: ConfigScope? {
        global || system || local ? scope : nil
    }

    func run() async throws {
        do {
            try await configure()
        } catch let error as Libgit2Error where error.message.hasPrefix("unable to read config file") {
            throw CLIError.stderr("fatal: \(error.message)", exitCode: 128)
        } catch let error as Libgit2Error where error.message.hasPrefix("unable to access") {
            // An existing file that can't be read: fatal for a list, a
            // warning and "not found" for a get.
            if list || writes { throw CLIError.stderr("fatal: \(error.message)", exitCode: 128) }
            Shell.current.stderr("warning: \(error.message)\n")
            throw CLIError(lines: [], exitCode: 1)
        } catch let error as Libgit2Error where error.message.hasPrefix("could not write config file") {
            // A selected file that is no file (`GIT_CONFIG_GLOBAL=`).
            throw CLIError.stderr("error: \(error.message)", exitCode: 4)
        } catch let error as Libgit2Error where error.message.contains("Permission denied") && scope != .local {
            // The scope's file can't be written or read, as git words it.
            let file = GitClient.configFile(for: scope)
            if writes {
                throw CLIError.stderr("error: could not lock config file \(file): Permission denied", exitCode: 255)
            }
            throw CLIError.stderr("fatal: unable to access '\(file)': Permission denied", exitCode: 128)
        } catch let error as Libgit2Error where GitClient.isNoRepository(error) {
            // `--local`, or a write with no scope, needs a repository.
            throw CLIError.stderr(
                local ? "fatal: --local can only be used inside a git repository"
                      : "fatal: not in a git directory",
                exitCode: 128)
        }
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
