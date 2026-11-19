import ArgumentParser
import GitLFSKit

struct LFSInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install Git LFS configuration.")
    @Flag(name: [.customShort("l"), .long]) var local = false
    @Flag(name: [.customShort("w"), .long]) var worktree = false
    @Flag var system = false
    @Option var file = ""
    @Flag(name: [.customShort("f"), .long]) var force = false
    @Flag(name: [.customShort("s"), .customLong("skip-smudge")]) var skipSmudge = false
    @Flag(name: .customLong("skip-repo")) var skipRepo = false
    @Flag(name: [.customShort("m"), .long]) var manual = false
    @Argument var arguments: [String] = []

    func run() async throws {
        var options = FilterOptions()
        options.local = local
        options.worktree = worktree
        options.system = system
        options.file = file
        options.force = force
        options.skipSmudge = skipSmudge
        options.skipRepo = skipRepo
        options.manual = manual
        try LFSCommand.emit(try await options.install(CommandContext.gitClient()))
    }
}
