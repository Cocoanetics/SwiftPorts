import ArgumentParser
import Foundation
import GitHub
import ForgeKit
import Sandbox

struct RepoClone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone a repository locally.",
        discussion: """
        Reads ~/.config/gh/config.yml's git_protocol (default: https)
        to pick the URL form. Passes through to `git clone` — your
        ssh-agent / credential helper / config all apply.
        """
    )

    @Argument(help: "Repository as OWNER/NAME (or just NAME for your own).")
    var repository: String

    @Argument(help: "Destination directory. Defaults to the repo name.")
    var directory: String?

    @Flag(name: .long, help: "Use HTTPS URL even if config prefers SSH.")
    var https: Bool = false

    @Flag(name: .long, help: "Use SSH URL even if config prefers HTTPS.")
    var ssh: Bool = false

    func run() async throws {
        if https && ssh {
            throw ValidationError("Specify --https OR --ssh, not both.")
        }

        // OWNER/NAME or just NAME (then OWNER = current user)
        let ref: RepositoryReference
        if repository.contains("/") {
            ref = try RepositoryReference(parsing: repository)
        } else {
            // Need the current user — go via GraphQL viewer{}.
            let gqlClient = try await CommandContext.graphQLClient()
            let viewer: ViewerQuery = try await gqlClient.query(ViewerQuery.query)
            ref = RepositoryReference(owner: viewer.viewer.login, name: repository)
        }

        // Verify the repo exists + learn the canonical clone URL.
        let client = try await CommandContext.apiClient()
        let repo: Repository = try await client.get("repos/\(ref.slug)")

        let url = try cloneURL(for: repo)
        let destDir = directory.map { Sandbox.resolve($0) }

        let git = CommandContext.gitClient()
        Stdio.print("Cloning \(repo.fullName) from \(url.absoluteString)…")
        try await git.clone(url: url, directory: destDir)
        Stdio.print("\(ANSI.green("✓")) Cloned \(repo.fullName)")
    }

    private func cloneURL(for repo: Repository) throws -> URL {
        let useSSH = ssh || (!https && preferSSH())
        if useSSH {
            // git@github.com:owner/name.git form
            let host = repo.htmlUrl.host ?? "github.com"
            return URL(string: "git@\(host):\(repo.fullName).git")!
        } else {
            // https://github.com/owner/name.git
            return URL(string: "\(repo.htmlUrl.absoluteString).git")!
        }
    }

    private func preferSSH() -> Bool {
        guard let configured = try? ConfigFileStore().read()["git_protocol"] else {
            return false
        }
        return configured.lowercased() == "ssh"
    }
}
