import ArgumentParser
import GitLFSKit
import ShellKit

struct LFSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lfs",
        abstract: "Git Large File Storage.",
        subcommands: [LFSVersionCommand.self, LFSEnvCommand.self, LFSPointerCommand.self, LFSInstall.self,
                      LFSUninstall.self, LFSTrack.self, LFSUntrack.self, LFSLsFiles.self, LFSStatus.self,
                      LFSFetch.self, LFSPush.self, LFSPrePush.self],
        helpNames: [])

    @Flag(name: [.customShort("v"), .long]) var version = false
    @Flag(name: [.customShort("h"), .customLong("help")]) var help = false
    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

    func run() async throws {
        if help || arguments == ["help"] {
            Shell.current.stdout.write(LFSHelp.text)
            return
        }
        if !arguments.isEmpty {
            var command = try Self.parseSubcommand(arguments)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return
        }
        Shell.print(LFSVersion.string)
        if !version { Shell.current.stdout.write(LFSHelp.text) }
    }

    /// Capture before dispatch so unknown subcommands receive Cobra's diagnostic and status.
    /// The recognized commands still use their own ArgumentParser declarations.
    static func parseSubcommand(_ arguments: [String]) throws -> any ParsableCommand {
        let name = arguments.first ?? ""
        if let type = configuration.subcommands.first(where: { $0.configuration.commandName == name }) {
            let args = Array(arguments.dropFirst())
            return try type.parseAsRoot(name == "fetch" ? LFSFetch.parserArguments(args) : args)
        }
        throw CLIError.stderr(
            "Error: unknown command \"\(name)\" for \"git-lfs\"\nRun 'git-lfs --help' for usage.",
            exitCode: 127)
    }

    static func emit(_ result: LFSCommandResult) throws {
        Shell.current.stdout.write(result.stdout)
        Shell.current.stderr.write(result.stderr)
        if result.status != 0 { throw CLIError(lines: [], exitCode: result.status) }
    }
}
