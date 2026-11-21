import ArgumentParser
import ForgeKit
import GitLFSKit

struct LFSPrePush: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pre-push", abstract: "Git LFS pre-push hook.")
    @Flag(name: [.customShort("d"), .long]) var dryRun = false
    @Argument var arguments: [String] = []

    func run() async throws {
        var options = PrePushOptions()
        options.dryRun = dryRun
        try LFSCommand.emit(try await options.run(arguments, client: CommandContext.lfsClient(),
                                                  git: CommandContext.gitClient(), terminal: TTY.isStderrTTY))
    }
}
