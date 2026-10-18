import ArgumentParser
import Foundation
import SwiftGit

struct RemoteSetURL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-url",
        abstract: "Change the URL associated with a remote."
    )

    @Argument(help: "Remote name (e.g. `origin`).")
    var name: String

    @Argument(help: "New URL.")
    var url: String

    func run() async throws {
        do {
            // Stored exactly as typed, as git does.
            try await CommandContext.gitClient().remoteSetURL(name: name, remote: url)
        } catch let err as Libgit2Error
            where err.message.lowercased().contains("not found") {
            throw CLIError.stderr(
                "error: No such remote '\(name)'", exitCode: 2)
        }
    }
}
