import ArgumentParser
import GitLFSKit
import ShellKit

struct LFSVersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "version", abstract: "Report the version number.")
    @Flag(name: [.customShort("c"), .long]) var comics = false
    @Argument var arguments: [String] = []

    func run() {
        Shell.print(LFSVersion.string)
        if comics { Shell.print("Nothing may see Gah Lak Tus and survive!") }
    }
}
