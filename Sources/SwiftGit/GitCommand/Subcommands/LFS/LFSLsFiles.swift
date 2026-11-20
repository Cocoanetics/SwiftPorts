import ArgumentParser
import GitLFSKit

struct LFSLsFiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls-files", abstract: "List Git LFS files.")
    @Flag(name: [.customShort("l"), .long]) var long = false
    @Flag(name: [.customShort("s"), .long]) var size = false
    @Flag(name: [.customShort("n"), .customLong("name-only")]) var nameOnly = false
    @Flag(name: [.customShort("d"), .long]) var debug = false
    @Flag(name: [.customShort("a"), .long]) var all = false
    @Flag var deleted = false
    @Flag(name: [.customShort("j"), .long]) var json = false
    @Option(name: [.customShort("I"), .long]) var include = ""
    @Option(name: [.customShort("X"), .long]) var exclude = ""
    @Argument var refs: [String] = []

    func run() async throws {
        var options = LsFilesOptions()
        options.long = long
        options.size = size
        options.nameOnly = nameOnly
        options.debug = debug
        options.all = all
        options.deleted = deleted
        options.json = json
        options.include = include
        options.exclude = exclude
        try LFSCommand.emit(try await options.lsFiles(refs, client: CommandContext.gitClient()))
    }
}
