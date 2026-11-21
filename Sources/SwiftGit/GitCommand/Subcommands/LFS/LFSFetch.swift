import ArgumentParser
import ForgeKit
import GitLFSKit

struct LFSFetch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fetch", abstract: "Download Git LFS objects.")
    @Flag(name: [.customShort("a"), .long]) var all = false
    @Option(name: [.customShort("I", allowingJoined: true), .long], parsing: .unconditional) var include: String?
    @Option(name: [.customShort("X", allowingJoined: true), .long], parsing: .unconditional) var exclude: String?
    @Flag(name: [.customShort("d"), .long]) var dryRun = false
    @Flag(name: [.customShort("j"), .long]) var json = false
    @Argument var arguments: [String] = []

    /// ArgumentParser drops empty attached values; Cobra uses them to clear configured paths.
    static func parserArguments(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var value = false
        var terminated = false
        for argument in arguments {
            if value { result.append(argument); value = false; continue }
            if argument == "--" { terminated = true }
            if !terminated && ["--include=", "--exclude=", "-I=", "-X="].contains(argument) {
                result += [String(argument.dropLast()), ""]
            } else {
                result.append(argument)
                value = !terminated && ["--include", "--exclude", "-I", "-X"].contains(argument)
            }
        }
        return result
    }

    func run() async throws {
        var options = FetchOptions()
        options.all = all
        options.include = include
        options.exclude = exclude
        options.dryRun = dryRun
        options.json = json
        try LFSCommand.emit(try await options.run(arguments, client: CommandContext.lfsClient(),
                                                  git: CommandContext.gitClient(), terminal: TTY.isStderrTTY))
    }
}
