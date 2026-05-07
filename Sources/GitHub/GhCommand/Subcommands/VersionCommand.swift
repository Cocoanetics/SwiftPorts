import ArgumentParser
import Sandbox

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the version of SwiftGH."
    )

    func run() async throws {
        Stdio.print("gh (SwiftGH port) 0.1.0-dev")
        Stdio.print("https://github.com/cocoanetics/SwiftGH")
    }
}
