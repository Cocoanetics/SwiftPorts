import ArgumentParser
import GitLFSKit

struct LFSEnvCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env", abstract: "Display the Git LFS environment.")
    @Argument var arguments: [String] = []

    func run() async throws {
        try LFSCommand.emit(await LFSEnv.run(client: CommandContext.gitClient()))
    }
}
