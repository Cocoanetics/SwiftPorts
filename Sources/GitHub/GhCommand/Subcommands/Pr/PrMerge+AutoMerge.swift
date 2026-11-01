import ArgumentParser
import Foundation
import ForgeKit
import GitHub
import ShellKit

extension PrMerge {
    /// Returns false when `--auto` should merge immediately, as upstream gh
    /// does for CLEAN, HAS_HOOKS, and UNSTABLE merge states.
    func configureAutoMerge(
        target: RepositoryReference,
        gql: GraphQLClient,
        method: PullRequestMergeRequest.MergeMethod?
    ) async throws -> Bool {
        let response: MergeStatusResponse = try await gql.query(
            """
            query($owner: String!, $name: String!, $number: Int!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  id
                  state
                  mergeStateStatus
                  baseRefName
                  isMergeQueueEnabled
                }
              }
            }
            """,
            variables: ["owner": .string(target.owner), "name": .string(target.name), "number": .int(number)])
        guard let pr = response.repository?.pullRequest else {
            throw ValidationError("No PR #\(number) on \(target.slug).")
        }

        var input: [String: GraphQLValue] = ["pullRequestId": .string(pr.id)]
        let mutation: String
        let message: String
        if disableAuto {
            mutation = PullRequestMutations.disablePullRequestAutoMerge
            message = "Auto-merge disabled for pull request \(target.slug)#\(number)"
        } else {
            if pr.state == "MERGED" { return true }
            if !pr.isMergeQueueEnabled,
               ["CLEAN", "HAS_HOOKS", "UNSTABLE"].contains(pr.mergeStateStatus) {
                guard method != nil else {
                    throw ValidationError("--merge, --rebase, or --squash required when not running interactively")
                }
                return false
            }
            guard let method = method ?? (pr.isMergeQueueEnabled ? .merge : nil) else {
                throw ValidationError("--merge, --rebase, or --squash required when not running interactively")
            }
            input["mergeMethod"] = .string(method.rawValue.uppercased())
            if let commitTitle, !commitTitle.isEmpty { input["commitHeadline"] = .string(commitTitle) }
            if let commitMessage { input["commitBody"] = .string(commitMessage) }
            mutation = PullRequestMutations.enablePullRequestAutoMerge
            if pr.isMergeQueueEnabled {
                message = "Pull request \(target.slug)#\(number) will be added to the merge queue for \(pr.baseRefName) when ready"
            } else {
                let via = method == .squash ? " via squash" : method == .rebase ? " via rebase" : ""
                message = "Pull request \(target.slug)#\(number) will be automatically merged\(via) when all requirements are met"
            }
        }
        let _: AutoMergeResponse = try await gql.query(mutation, variables: ["input": .object(input)])
        if TTY.isStdoutTTY {
            Shell.current.stderr.write(Data("\(ANSI.green("✓")) \(message)\n".utf8))
        }
        return true
    }

    private struct AutoMergeResponse: Decodable, Sendable {}

    private struct MergeStatusResponse: Decodable, Sendable {
        let repository: Repository?
        struct Repository: Decodable, Sendable {
            let pullRequest: PullRequest?
        }
        struct PullRequest: Decodable, Sendable {
            let id: String
            let state: String
            let mergeStateStatus: String
            let baseRefName: String
            let isMergeQueueEnabled: Bool
        }
    }
}
