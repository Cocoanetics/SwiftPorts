import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct PrView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "View a pull request."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    @Flag(name: .long, help: "Also fetch and print the PR's comments.")
    var comments: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: PrFields.map)
            let gql = try await CommandContext.graphQLClient()
            let response: PullRequestViewResponse = try await gql.query(
                PullRequestQueries.view(),
                variables: [
                    "owner":  .string(target.owner),
                    "name":   .string(target.name),
                    "number": .int(number),
                ])
            guard let pr = response.repository?.pullRequest else {
                throw ValidationError("No PR #\(number) on \(target.slug).")
            }
            Stdio.print(try JSONFieldSelector.render(item: pr, fields: fields, fieldMap: PrFields.map))
            return
        }

        let client = try await CommandContext.apiClient()
        let pr: PullRequest = try await client.get(
            "repos/\(target.slug)/pulls/\(number)")

        Stdio.print("\(ANSI.bold("#\(pr.number)"))  \(ANSI.bold(pr.title))")
        let stateColor: String
        if pr.merged == true { stateColor = ANSI.magenta("merged") }
        else if pr.state == .open { stateColor = ANSI.green("open") }
        else { stateColor = ANSI.red("closed") }
        let draftSuffix = pr.draft == true ? ANSI.dim(" (draft)") : ""
        Stdio.print("state: \(stateColor)\(draftSuffix)  author: @\(pr.user.login)")
        Stdio.print("\(pr.head.ref) → \(pr.base.ref)")
        Stdio.print("created: \(ISO8601DateFormatter().string(from: pr.createdAt))")
        if let merged = pr.merged, merged, let when = pr.mergedAt {
            Stdio.print("merged: \(ISO8601DateFormatter().string(from: when))")
        }
        if !pr.labels.isEmpty {
            Stdio.print("labels: \(pr.labels.map(\.name).joined(separator: ", "))")
        }
        Stdio.print("url: \(pr.htmlUrl.absoluteString)")
        if let body = pr.body, !body.isEmpty {
            Stdio.print("\n--\n\(body)")
        }
        if comments {
            try await renderComments(target: target, client: client)
        }
    }

    /// Fetch + pretty-print the PR's discussion thread. PRs share
    /// GitHub's `/issues/<n>/comments` endpoint with issues — review
    /// comments live elsewhere and aren't part of this feed.
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
