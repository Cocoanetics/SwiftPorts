import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct IssueNote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Comment on an issue.",
        aliases: ["comment"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Issue IID, `#IID`, or full issue URL.")
    var issue: String

    @Option(name: [.customShort("m"), .long],
            help: "Comment body.")
    var message: String

    private struct CreateNote: Encodable {
        let body: String
    }

    func run() async throws {
        let parsed = try IssueArgument.parse(issue)
        let target: RepositoryReference
        if let fromURL = parsed.repoFromURL {
            target = fromURL
        } else {
            target = try await CommandContext.resolveRepo(flag: repo)
        }
        let client = try await CommandContext.apiClient(host: target.host)
        let path = "projects/\(target.encodedPath)/issues/\(parsed.iid)/notes"
        let note: Note = try await client.send(
            method: .post, path: path, body: CreateNote(body: message))
        Stdio.print("Posted note \(note.id) on #\(parsed.iid).")
    }
}
