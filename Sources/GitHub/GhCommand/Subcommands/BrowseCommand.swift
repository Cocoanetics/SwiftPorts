import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct BrowseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browse",
        abstract: "Open a repository or one of its resources in the browser.",
        discussion: """
        Without options, opens the repo's home page.

        Examples:
          gh browse                              # repo home page
          gh browse --branch main                # branch view
          gh browse README.md                    # file in default branch
          gh browse README.md --branch dev       # file on a branch
          gh browse 42                           # issue or PR #42
          gh browse --commit abc123              # commit
          gh browse --releases                   # releases tab
          gh browse --settings                   # repo settings
        """
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Optional file path or issue/PR number.")
    var target: String?

    @Option(name: [.customShort("b"), .customLong("branch")],
            help: "Branch to use for file paths.")
    var branch: String?

    @Option(name: .customLong("commit"), help: "Open a specific commit.")
    var commit: String?

    @Flag(name: .long, help: "Open the releases tab.")
    var releases: Bool = false

    @Flag(name: .long, help: "Open the wiki.")
    var wiki: Bool = false

    @Flag(name: .long, help: "Open the projects tab.")
    var projects: Bool = false

    @Flag(name: .long, help: "Open the settings page.")
    var settings: Bool = false

    @Flag(name: [.customShort("n"), .customLong("no-browser")],
          help: "Print the URL instead of opening it.")
    var noBrowser: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let url = try await buildURL(repo: target)

        if noBrowser {
            Stdio.print(url.absoluteString)
            return
        }
        do {
            try await Browser.open(url)
        } catch {
            // Fall back to printing the URL — better than failing silently.
            Stdio.stderr.write(Data(
                "Couldn't open browser: \(error.localizedDescription)\n".utf8))
            Stdio.print(url.absoluteString)
        }
    }

    private func buildURL(repo target: RepositoryReference) async throws -> URL {
        let base = "https://github.com/\(target.slug)"

        if let commit { return URL(string: "\(base)/commit/\(commit)")! }
        if releases { return URL(string: "\(base)/releases")! }
        if wiki { return URL(string: "\(base)/wiki")! }
        if projects { return URL(string: "\(base)/projects")! }
        if settings { return URL(string: "\(base)/settings")! }

        // Numeric target → /issues/N (works for PRs too: GitHub redirects).
        if let target = self.target, let n = Int(target), !target.isEmpty {
            _ = n
            return URL(string: "\(base)/issues/\(target)")!
        }

        // Path target → blob/tree view on a branch.
        if let path = self.target {
            let ref = try await resolvedBranch(for: target)
            return URL(string: "\(base)/blob/\(ref)/\(path)")!
        }

        // Bare branch view.
        if let branch {
            return URL(string: "\(base)/tree/\(branch)")!
        }

        // Default: repo home.
        return URL(string: base)!
    }

    private func resolvedBranch(
        for target: RepositoryReference
    ) async throws -> String {
        if let branch { return branch }
        // Look up the default branch via the API. One extra round-trip,
        // but only when the user passed a path — most invocations skip this.
        let client = try await CommandContext.apiClient()
        let repo: Repository = try await client.get("repos/\(target.slug)")
        return repo.defaultBranch
    }
}
