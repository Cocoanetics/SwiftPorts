import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct VariableUnset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unset",
        abstract: "Delete a CI/CD variable."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Variable name.")
    var key: String

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        _ = try await client.raw(
            method: .delete,
            path: "projects/\(target.encodedPath)/variables/\(key)")
        Stdio.print("Deleted \(key)")
    }
}
