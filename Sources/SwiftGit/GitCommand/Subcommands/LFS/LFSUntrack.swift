import ArgumentParser
import GitLFSKit

struct LFSUntrack: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "untrack", abstract: "Remove Git LFS paths.")
    @Argument var patterns: [String] = []

    func run() async throws {
        try LFSCommand.emit(try await TrackOptions().untrack(patterns, client: CommandContext.gitClient()))
    }
}
