import ArgumentParser
import Sandbox
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

    func run() async throws {
        let client = CommandContext.gitClient()

        if list {
            let entries = try await client.configList()
            for (name, value) in entries {
                Stdio.print("\(name)=\(value)")
            }
            return
        }

        if unset {
            guard let name = args.first else {
                throw CLIError.stderr(
                    "fatal: --unset requires a key", exitCode: 128)
            }
            _ = try await client.configUnset(name, scope: scope)
            return
        }

        switch args.count {
        case 1:
            // Read form: `git config <name>` or `git config --get <name>`.
            let name = args[0]
            if let value = try await client.configGet(name, scope: scope) {
                Stdio.print(value)
            } else {
                throw CLIError.stderr("", exitCode: 1)
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
