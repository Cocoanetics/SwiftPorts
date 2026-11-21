import ArgumentParser
import ForgeKit
import GitLFSKit

struct LFSCheckout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkout",
        abstract: "Populate working copy with real content from Git LFS files.")
    @Flag(name: .long) var base = false
    @Flag(name: .long) var ours = false
    @Flag(name: .long) var theirs = false
    @Option(name: .long) var to: String?
    @Argument var arguments: [String] = []

    func run() async throws {
        var options = CheckoutOptions()
        options.base = base
        options.ours = ours
        options.theirs = theirs
        options.to = to
        try LFSCommand.emit(try await options.run(
            arguments, client: CommandContext.lfsClient(),
            git: CommandContext.gitClient(), terminal: TTY.isStdoutTTY))
    }
}
