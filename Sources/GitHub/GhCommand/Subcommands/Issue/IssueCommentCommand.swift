import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct IssueCommentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "comment",
        abstract: "Add a comment to an issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    @Option(name: [.short, .customLong("body")],
            help: "Comment body. Use - to read from stdin.")
    var body: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let resolvedBody: String
        if body == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            resolvedBody = String(data: data, encoding: .utf8) ?? ""
        } else {
            resolvedBody = body
        }
        guard !resolvedBody.isEmpty else {
            throw ValidationError("Comment body is empty.")
        }
        let request = IssueCommentRequest(body: resolvedBody)
        let client = try await CommandContext.apiClient()
        let comment: IssueComment = try await client.send(
            method: .post,
            path: "repos/\(target.slug)/issues/\(number)/comments",
            body: request)
        Stdio.print("✓ Commented on #\(number)")
        Stdio.print(comment.htmlUrl.absoluteString)
    }
}
