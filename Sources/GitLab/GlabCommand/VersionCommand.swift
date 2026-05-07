import ArgumentParser
import Sandbox

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the version."
    )

    func run() async throws {
        Stdio.print("glab 0.1.0-dev (SwiftPorts)")
    }
}
