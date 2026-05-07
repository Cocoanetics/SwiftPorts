import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct PrReady: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ready",
        abstract: "Mark a draft pull request as ready for review.",
        discussion: """
        REST does not expose a direct 'undraft' field; this uses the
        GraphQL markPullRequestReadyForReview mutation, which targets
        the PR by node ID. We fetch the PR first to get the ID.
        """
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    @Flag(name: .customLong("undo"),
          help: "Convert a ready PR back to a draft (markPullRequestDraft).")
    var undo: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let api = try await CommandContext.apiClient()
        let pr: PullRequest = try await api.get("repos/\(target.slug)/pulls/\(number)")

        let mutation = undo
            ? "mutation($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { id } } }"
            : "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { id } } }"

        let gql = try await CommandContext.graphQLClient()
        struct EmptyResponse: Codable, Sendable {}
        let _: EmptyResponse = try await gql.query(
            mutation, variables: ["id": .string(pr.nodeId)])
        if undo {
            Stdio.print("\(ANSI.green("✓")) Marked #\(number) as draft")
        } else {
            Stdio.print("\(ANSI.green("✓")) Marked #\(number) as ready for review")
        }
    }
}
