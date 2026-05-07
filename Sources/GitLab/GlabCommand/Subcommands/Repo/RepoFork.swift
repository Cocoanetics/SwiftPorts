import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct RepoFork: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fork",
        abstract: "Fork a GitLab project."
    )

    @Argument(help: "Project to fork (OWNER/REPO, GROUP/SUB/REPO, HOST/...).")
    var project: RepositoryReference

    @Option(name: [.customShort("g"), .customLong("namespace")],
            help: "Group / namespace full path to fork into. Defaults to your user namespace.")
    var namespace: String?

    @Option(name: .customLong("name"),
            help: "Override the fork's name.")
    var name: String?

    @Option(name: .customLong("path"),
            help: "Override the fork's path slug.")
    var path: String?

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    private struct ForkRequest: Encodable {
        let namespacePath: String?
        let name: String?
        let path: String?
    }

    func run() async throws {
        let client = try await CommandContext.apiClient(host: project.host)
        let request = ForkRequest(namespacePath: namespace, name: name, path: path)
        let fork: Project = try await client.send(
            method: .post,
            path: "projects/\(project.encodedPath)/fork",
            body: request)
        if json {
            Stdio.print(try CodableOutput.prettyJSON(fork))
            return
        }
        Stdio.print("\(ANSI.green("✓")) Forked into \(ANSI.bold(fork.pathWithNamespace))")
        Stdio.print("  web:  \(fork.webUrl.absoluteString)")
    }
}
