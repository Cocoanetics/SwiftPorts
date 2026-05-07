import ArgumentParser
import Foundation
import GitHub
import ForgeKit
import Sandbox

struct RepoFork: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fork",
        abstract: "Fork a repository to your account."
    )

    @Argument(help: "Repository as OWNER/NAME. Omit to fork the cwd's origin.")
    var repository: RepositoryReference?

    @Option(name: .customLong("org"),
            help: "Fork into an organization instead of your account.")
    var org: String?

    @Flag(name: .long, help: "Clone the fork locally after creation.")
    var clone: Bool = false

    @Option(name: .customLong("fork-name"),
            help: "Rename the fork.")
    var forkName: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repository)

        // POST /repos/{owner}/{repo}/forks — body is optional;
        // include `organization` when forking into an org.
        struct ForkRequest: Codable {
            var organization: String?
            var name: String?
            var defaultBranchOnly: Bool?
        }
        let request = ForkRequest(
            organization: org,
            name: forkName,
            defaultBranchOnly: nil)

        let client = try await CommandContext.apiClient()
        let fork: Repository = try await client.send(
            method: .post,
            path: "repos/\(target.slug)/forks",
            body: request)
        Stdio.print("\(ANSI.green("✓")) Forked \(target.slug) → \(fork.fullName)")

        if clone {
            let url = URL(string: "\(fork.htmlUrl.absoluteString).git")!
            let git = CommandContext.gitClient()
            try await git.clone(url: url, directory: nil)
            Stdio.print("\(ANSI.green("✓")) Cloned fork to ./\(fork.name)")
            // Add upstream remote so users can keep their fork in sync.
            let upstreamURL = URL(string: "\(target.urlString)")!
            let cwd = Sandbox.currentDirectory
                .appendingPathComponent(fork.name, isDirectory: true)
            let cloneGit = CommandContext.gitClient(workingDirectory: cwd)
            try await cloneGit.addRemote(name: "upstream", url: upstreamURL)
            Stdio.print("\(ANSI.green("✓")) Added upstream remote → \(target.slug)")
        }
    }
}

private extension RepositoryReference {
    var urlString: String { "https://github.com/\(slug).git" }
}
