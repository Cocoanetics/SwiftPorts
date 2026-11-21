import ArgumentParser
import GitLFSKit

struct LFSStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show Git LFS file status.")
    @Flag(name: [.customShort("p"), .long]) var porcelain = false
    @Flag(name: [.customShort("j"), .long]) var json = false
    @Argument var arguments: [String] = []

    func run() async throws {
        var options = StatusOptions()
        options.porcelain = porcelain
        options.json = json
        try LFSCommand.emit(try await options.status(client: CommandContext.gitClient()))
    }
}
