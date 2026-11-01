import ArgumentParser
import ShellKit
import Foundation
import GitHub
import ForgeKit

struct PrMerge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge a pull request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    @Flag(name: .customLong("merge"),
          help: "Merge the commits with a merge commit (default).")
    var merge: Bool = false

    @Flag(name: .customLong("squash"),
          help: "Squash commits into one before merging.")
    var squash: Bool = false

    @Flag(name: .customLong("rebase"),
          help: "Rebase commits onto the base branch.")
    var rebase: Bool = false

    @Flag(name: .customLong("auto"),
          help: "Automatically merge only after necessary requirements are met.")
    var auto: Bool = false

    @Flag(name: .customLong("disable-auto"),
          help: "Disable auto-merge for this pull request.")
    var disableAuto: Bool = false

    @Option(name: .customLong("subject"),
            help: "Override the commit subject for merge/squash.")
    var commitTitle: String?

    @Option(name: .customLong("body"),
            help: "Override the commit body for merge/squash.")
    var commitMessage: String?

    func validate() throws {
        let methodCount = [merge, squash, rebase].filter { $0 }.count
        if methodCount > 1 {
            throw ValidationError("Specify only one of --merge / --squash / --rebase.")
        }
        if auto && disableAuto {
            throw ValidationError("Specify only one of --auto or --disable-auto.")
        }
    }

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let api = try await CommandContext.apiClient()
        let gql = try await CommandContext.graphQLClient()
        try await run(target: target, api: api, gql: gql)
    }

    func run(target: RepositoryReference, api: APIClient, gql: GraphQLClient) async throws {
        try validate()
        let method: PullRequestMergeRequest.MergeMethod?
        if squash { method = .squash }
        else if rebase { method = .rebase }
        else if merge { method = .merge }
        else { method = nil }   // defer to repo's default merge method

        if auto || disableAuto {
            if try await configureAutoMerge(target: target, gql: gql, method: method) { return }
        }

        let request = PullRequestMergeRequest(
            commitTitle: commitTitle,
            commitMessage: commitMessage,
            mergeMethod: method)
        let response: PullRequestMergeResponse = try await api.send(
            method: .put,
            path: "repos/\(target.slug)/pulls/\(number)/merge",
            body: request)
        if response.merged {
            Shell.print("\(ANSI.green("✓")) Merged #\(number) (\(String(response.sha.prefix(7))))")
        } else {
            Shell.print("\(ANSI.red("✗")) Merge failed: \(response.message ?? "unknown reason")")
            throw ExitCode(1)
        }
    }
}
