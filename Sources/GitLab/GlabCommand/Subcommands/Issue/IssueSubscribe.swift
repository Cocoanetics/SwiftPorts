import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct IssueSubscribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subscribe",
        abstract: "Subscribe to an issue."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Issue IID, `#IID`, or full issue URL.")
    var issue: String

    private struct EmptyBody: Encodable {}

    func run() async throws {
        let parsed = try IssueArgument.parse(issue)
        let target: RepositoryReference
        if let fromURL = parsed.repoFromURL {
            target = fromURL
        } else {
            target = try await CommandContext.resolveRepo(flag: repo)
        }
        let client = try await CommandContext.apiClient(host: target.host)
        let path = "projects/\(target.encodedPath)/issues/\(parsed.iid)/subscribe"
        try await client.send(method: .post, path: path, body: EmptyBody())
        Stdio.print("Subscribed to #\(parsed.iid).")
    }
}

struct IssueUnsubscribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unsubscribe",
        abstract: "Unsubscribe from an issue."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Issue IID, `#IID`, or full issue URL.")
    var issue: String

    private struct EmptyBody: Encodable {}

    func run() async throws {
        let parsed = try IssueArgument.parse(issue)
        let target: RepositoryReference
        if let fromURL = parsed.repoFromURL {
            target = fromURL
        } else {
            target = try await CommandContext.resolveRepo(flag: repo)
        }
        let client = try await CommandContext.apiClient(host: target.host)
        let path = "projects/\(target.encodedPath)/issues/\(parsed.iid)/unsubscribe"
        try await client.send(method: .post, path: path, body: EmptyBody())
        Stdio.print("Unsubscribed from #\(parsed.iid).")
    }
}
