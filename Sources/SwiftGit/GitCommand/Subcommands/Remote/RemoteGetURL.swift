import ArgumentParser
import Sandbox

struct RemoteGetURL: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get-url",
        abstract: "Print the URL configured for the named remote."
    )

    @Argument(help: "Remote name to look up (e.g. `origin`).")
    var name: String

    func run() async throws {
        let client = CommandContext.gitClient()
        if let url = try await client.remoteURL(named: name) {
            Stdio.print(url.absoluteString)
            return
        }
        throw CLIError.stderr("error: No such remote '\(name)'", exitCode: 2)
    }
}
