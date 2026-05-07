import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct ReleaseDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a release (the underlying tag stays — `glab tag` for that)."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Tag name of the release to delete.")
    var tagName: String

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let encoded = tagName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? tagName
        _ = try await client.raw(
            method: .delete,
            path: "projects/\(target.encodedPath)/releases/\(encoded)")
        Stdio.print("Deleted release \(tagName)")
    }
}
