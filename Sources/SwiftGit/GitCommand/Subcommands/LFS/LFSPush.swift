import ArgumentParser
import ForgeKit
import GitLFSKit

struct LFSPush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "push", abstract: "Upload Git LFS objects.")
    @Flag(name: [.customShort("a"), .long]) var all = false
    @Flag(name: [.customShort("d"), .long]) var dryRun = false
    @Flag(name: [.customShort("o"), .customLong("object-id")]) var objectID = false
    @Flag var stdin = false
    @Argument var arguments: [String] = []

    func run() async throws {
        var options = PushOptions()
        options.all = all
        options.dryRun = dryRun
        options.objectID = objectID
        options.stdin = stdin
        try LFSCommand.emit(try await options.run(arguments, client: CommandContext.lfsClient(),
                                                  git: CommandContext.gitClient(), terminal: TTY.isStderrTTY))
    }
}
