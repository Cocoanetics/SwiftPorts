import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct RepoCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new repository.",
        discussion: """
        Without OWNER/NAME, creates under your own account.

        Use --org to create in an organization:
          gh repo create my-thing --org Cocoanetics --private --description "…"
        """
    )

    @Argument(help: "Repository name (or OWNER/NAME).")
    var name: String

    @Option(name: .long, help: "Create in an organization.")
    var org: String?

    @Option(name: [.short, .customLong("description")],
            help: "Repository description.")
    var description: String?

    @Option(name: [.customLong("homepage")], help: "Project homepage URL.")
    var homepage: String?

    @Flag(name: [.customLong("private")],
          help: "Make the repo private (default: public).")
    var isPrivate: Bool = false

    @Flag(name: [.customLong("internal")],
          help: "Make the repo internal (org accounts only).")
    var isInternal: Bool = false

    @Flag(name: .customLong("disable-issues"),
          help: "Disable issues on the new repo.")
    var disableIssues: Bool = false

    @Flag(name: .customLong("disable-wiki"),
          help: "Disable wiki on the new repo.")
    var disableWiki: Bool = false

    @Option(name: .customLong("gitignore"),
            help: "Apply a .gitignore template (e.g. Swift, Go).")
    var gitignore: String?

    @Option(name: [.customLong("license")],
            help: "Apply a license template (e.g. mit, apache-2.0).")
    var license: String?

    @Flag(name: .customLong("add-readme"),
          help: "Initialize the repo with a README.")
    var addReadme: Bool = false

    @Flag(name: .long, help: "Clone the new repo locally after creating.")
    var clone: Bool = false

    func run() async throws {
        // OWNER/NAME on the positional implicitly sets --org.
        var owner = org
        var repoName = name
        if name.contains("/") {
            let parts = name.split(separator: "/", maxSplits: 1)
            if parts.count == 2 {
                owner = String(parts[0])
                repoName = String(parts[1])
            }
        }

        let visibility: Visibility?
        if isInternal { visibility = .internal }
        else if isPrivate { visibility = .private }
        else { visibility = .public }

        let request = RepoCreateRequest(
            name: repoName,
            description: description,
            homepage: homepage,
            private: isPrivate ? true : nil,
            visibility: visibility,
            hasIssues: disableIssues ? false : nil,
            hasProjects: nil,
            hasWiki: disableWiki ? false : nil,
            autoInit: addReadme ? true : nil,
            gitignoreTemplate: gitignore,
            licenseTemplate: license
        )

        let path = owner.map { "orgs/\($0)/repos" } ?? "user/repos"
        let client = try await CommandContext.apiClient()
        let repo: Repository = try await client.send(
            method: .post, path: path, body: request)
        Stdio.print("\(ANSI.green("✓")) Created \(repo.fullName)")
        Stdio.print(repo.htmlUrl.absoluteString)

        if clone {
            let cloneURL = URL(string: "\(repo.htmlUrl.absoluteString).git")!
            let git = CommandContext.gitClient()
            try await git.clone(url: cloneURL, directory: nil)
            Stdio.print("\(ANSI.green("✓")) Cloned to ./\(repo.name)")
        }
    }
}
