import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct IssueDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an issue."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Issue IID, `#IID`, or full issue URL.")
    var issue: String

    func run() async throws {
        let parsed = try IssueArgument.parse(issue)
        let target: RepositoryReference
        if let fromURL = parsed.repoFromURL {
            target = fromURL
        } else {
            target = try await CommandContext.resolveRepo(flag: repo)
        }
        let client = try await CommandContext.apiClient(host: target.host)
        let path = "projects/\(target.encodedPath)/issues/\(parsed.iid)"
        try await client.delete(path)
        Stdio.print("Deleted #\(parsed.iid).")
    }
}
