import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct IssueView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "View an issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    @Flag(name: .long, help: "Also fetch and print the issue's comments.")
    var comments: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: IssueFields.map)
            let gql = try await CommandContext.graphQLClient()
            let response: IssueViewResponse = try await gql.query(
                IssueQueries.view,
                variables: [
                    "owner":  .string(target.owner),
                    "name":   .string(target.name),
                    "number": .int(number),
                ])
            guard let issue = response.repository?.issue else {
                throw ValidationError("No issue #\(number) on \(target.slug).")
            }
            Stdio.print(try JSONFieldSelector.render(item: issue, fields: fields, fieldMap: IssueFields.map))
            return
        }

        let client = try await CommandContext.apiClient()
        let issue: Issue = try await client.get(
            "repos/\(target.slug)/issues/\(number)")

        Stdio.print("\(ANSI.bold("#\(issue.number)"))  \(ANSI.bold(issue.title))")
        let stateColor: String = issue.state == .open ? ANSI.green("open") : ANSI.magenta("closed")
        Stdio.print("state: \(stateColor)  author: @\(issue.user.login)")
        Stdio.print("created: \(ISO8601DateFormatter().string(from: issue.createdAt))")
        if !issue.labels.isEmpty {
            Stdio.print("labels: \(issue.labels.map(\.name).joined(separator: ", "))")
        }
        Stdio.print("url: \(issue.htmlUrl.absoluteString)")
        if let body = issue.body, !body.isEmpty {
            Stdio.print("\n--\n\(body)")
        }
        if comments {
            try await renderComments(target: target, client: client)
        }
    }

    /// Fetch + pretty-print the issue's discussion thread.
    private func renderComments(target: RepositoryReference, client: APIClient) async throws {
        let list: [IssueComment] = try await client.get(
            "repos/\(target.slug)/issues/\(number)/comments")
        guard !list.isEmpty else {
            Stdio.print("\n--\n(no comments)")
            return
        }
        Stdio.print("\n--\n\(ANSI.bold("Comments (\(list.count))"))")
        let f = ISO8601DateFormatter()
        for comment in list {
            Stdio.print("\n@\(comment.user.login)  \(f.string(from: comment.createdAt))")
            if let body = comment.body, !body.isEmpty {
                Stdio.print(body)
            }
        }
    }
}
