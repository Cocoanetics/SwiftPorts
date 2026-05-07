import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct TagDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a repository tag."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Tag name to delete.")
    var tagName: String

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let encoded = tagName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? tagName
        _ = try await client.raw(
            method: .delete,
            path: "projects/\(target.encodedPath)/repository/tags/\(encoded)")
        Stdio.print("Deleted tag \(tagName)")
    }
}
