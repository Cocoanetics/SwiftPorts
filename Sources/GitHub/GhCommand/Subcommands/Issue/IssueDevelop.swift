import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct IssueDevelop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "develop",
        abstract: "Create a branch on the repo linked to an issue."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Issue number.")
    var number: Int

    @Option(name: [.short, .customLong("name")],
            help: "Branch name (default: derived from the issue title).")
    var branchName: String?

    @Option(name: [.customShort("b"), .customLong("base")],
            help: "Base ref to fork from (default: repo's default branch).")
    var base: String?

    @Flag(name: .long,
          help: "Also check out the new branch locally after creating it.")
    var checkout: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let api = try await CommandContext.apiClient()

        // 1. Resolve issue node ID + the OID of the base ref's tip.
        let issue: Issue = try await api.get("repos/\(target.slug)/issues/\(number)")
        let repository: Repository = try await api.get("repos/\(target.slug)")
        let baseRef = base ?? repository.defaultBranch
        let refResp: GitRef = try await api.get(
            "repos/\(target.slug)/git/ref/heads/\(baseRef)")
        let oid = refResp.object.sha

        // 2. createLinkedBranch mutation.
        let gql = try await CommandContext.graphQLClient()
        let mutation = """
            mutation($issueId: ID!, $oid: GitObjectID!, $name: String) {
              createLinkedBranch(input: {issueId: $issueId, oid: $oid, name: $name}) {
                linkedBranch {
                  id
                  ref {
                    name
                    repository { url }
                  }
                }
              }
            }
            """
        var variables: [String: GraphQLValue] = [
            "issueId": .string(issue.nodeId),
            "oid": .string(oid),
        ]
        if let branchName { variables["name"] = .string(branchName) }

        struct Response: Codable, Sendable {
            let createLinkedBranch: Inner
            struct Inner: Codable, Sendable {
                let linkedBranch: LinkedBranch
            }
            struct LinkedBranch: Codable, Sendable {
                let id: String
                let ref: Ref
            }
            struct Ref: Codable, Sendable {
                let name: String
                let repository: RepoStub
            }
            struct RepoStub: Codable, Sendable { let url: URL }
        }
        let response: Response = try await gql.query(mutation, variables: variables)
        let createdName = response.createLinkedBranch.linkedBranch.ref.name
        Stdio.print("\(ANSI.green("✓")) Created branch \(createdName) linked to #\(number)")

        if checkout {
            let git = CommandContext.gitClient()
            try await git.fetch(remote: "origin", refspec: createdName)
            try await git.checkout(ref: createdName)
            Stdio.print("\(ANSI.green("✓")) Checked out \(createdName)")
        }
    }
}

private struct GitRef: Codable, Sendable {
    let ref: String
    let nodeId: String
    let url: URL
    let object: GitObject
}

private struct GitObject: Codable, Sendable {
    let sha: String
    let type: String
    let url: URL
}
