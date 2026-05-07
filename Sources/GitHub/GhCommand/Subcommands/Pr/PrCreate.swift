import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct PrCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a pull request.",
        discussion: """
        Defaults --head to your current branch and pushes it to origin
        if it doesn't already track an upstream.

        Title and body are required. Pipe a markdown file via:
          gh pr create --title "Add foo" --body "$(cat PR-TEMPLATE.md)"
        """
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("title")], help: "PR title.")
    var title: String

    @Option(name: [.short, .customLong("body")],
            help: "PR body. Use - to read from stdin.")
    var body: String?

    @Option(name: [.customShort("B"), .customLong("base")],
            help: "Base branch (defaults to the repo's default branch).")
    var base: String?

    @Option(name: [.customShort("H"), .customLong("head")],
            help: "Head branch (defaults to the current branch).")
    var head: String?

    @Flag(name: .long, help: "Open as a draft PR.")
    var draft: Bool = false

    @Flag(name: .customLong("no-maintainer-edit"),
          help: "Disallow maintainer edits to your branch.")
    var noMaintainerEdit: Bool = false

    @Flag(name: .customLong("no-push"),
          help: "Skip the auto-push of the head branch.")
    var noPush: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let git = CommandContext.gitClient()

        let resolvedHead: String
        if let head { resolvedHead = head }
        else if let current = try await git.currentBranch() { resolvedHead = current }
        else {
            throw ValidationError(
                "No --head specified and current branch is detached / not in a git repo.")
        }

        // Push the branch if it doesn't track an upstream and the
        // user didn't pass --no-push.
        if !noPush {
            let upstream = try await git.upstreamBranch(of: resolvedHead)
            if upstream == nil {
                Stdio.print("Pushing \(resolvedHead) to origin…")
                try await git.push(
                    remote: "origin",
                    refspec: resolvedHead,
                    setUpstream: true)
            }
        }

        // Look up the repo to learn its default branch when --base is missing.
        let client = try await CommandContext.apiClient()
        let resolvedBase: String
        if let base { resolvedBase = base }
        else {
            let repo: Repository = try await client.get("repos/\(target.slug)")
            resolvedBase = repo.defaultBranch
        }

        let resolvedBody: String?
        if body == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            resolvedBody = String(data: data, encoding: .utf8)
        } else {
            resolvedBody = body
        }

        let request = PullRequestCreateRequest(
            title: title,
            head: resolvedHead,
            base: resolvedBase,
            body: resolvedBody,
            draft: draft ? true : nil,
            maintainerCanModify: noMaintainerEdit ? false : nil)
        let pr: PullRequest = try await client.send(
            method: .post,
            path: "repos/\(target.slug)/pulls",
            body: request)
        Stdio.print("\(ANSI.green("✓")) Opened PR #\(pr.number)")
        Stdio.print(pr.htmlUrl.absoluteString)
    }
}
