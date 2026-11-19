import ArgumentParser
import GitLFSKit

struct LFSPointerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pointer", abstract: "Build and compare pointers.")
    @Option(name: [.customShort("f"), .long]) var file = ""
    @Option(name: [.customShort("p"), .long]) var pointer = ""
    @Flag var stdin = false
    @Flag var check = false
    @Flag var strict = false
    @Flag(name: .customLong("no-strict")) var noStrict = false
    @Argument var arguments: [String] = []

    func run() async throws {
        var options = LFSPointerOptions()
        options.file = file
        options.pointer = pointer
        options.stdin = stdin
        options.check = check
        options.strict = strict
        options.noStrict = noStrict
        try LFSCommand.emit(try await options.run())
    }
}
