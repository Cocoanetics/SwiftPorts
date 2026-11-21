import ArgumentParser
import ForgeKit
import GitLFSKit

struct LFSPull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Fetch Git LFS changes from the remote & checkout any required working tree files.")
    @Option(name: [.customShort("I", allowingJoined: true), .long], parsing: .unconditional) var include: String?
    @Option(name: [.customShort("X", allowingJoined: true), .long], parsing: .unconditional) var exclude: String?
    @Argument var arguments: [String] = []

    /// ArgumentParser drops empty `--option=` values; Cobra/pflag treats them as empty strings
    /// while short `-I=` binds `"="` literally.
    static func parserArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var value = false
        var terminated = false
        for argument in arguments {
            if value { result.append(argument); value = false; continue }
            if argument == "--" { terminated = true }
            if !terminated && (argument == "--include=" || argument == "--exclude=") {
                result += [String(argument.dropLast()), ""]
            } else if !terminated && (argument == "-I=" || argument == "-X=") {
                result += [String(argument.dropLast()), "="]
            } else {
                result.append(argument)
                value = !terminated && ["--include", "--exclude", "-I", "-X"].contains(argument)
            }
        }
        return result
    }

    func run() async throws {
        var options = PullOptions()
        options.include = include
        options.exclude = exclude
        try LFSCommand.emit(try await options.run(
            arguments, client: CommandContext.lfsClient(),
            git: CommandContext.gitClient(), terminal: TTY.isStdoutTTY))
    }
}
