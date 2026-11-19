import ArgumentParser
import GitLFSKit

struct LFSUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall", abstract: "Remove Git LFS hooks and filter configuration.")
    @Flag(name: [.customShort("l"), .long]) var local = false
    @Flag(name: [.customShort("w"), .long]) var worktree = false
    @Flag var system = false
    @Option var file = ""
    @Flag(name: .customLong("skip-repo")) var skipRepo = false
    @Argument var arguments: [String] = []

    func run() async throws {
        var options = FilterOptions()
        options.local = local
        options.worktree = worktree
        options.system = system
        options.file = file
        options.skipRepo = skipRepo
        try LFSCommand.emit(try await options.uninstall(CommandContext.gitClient()))
    }
}
