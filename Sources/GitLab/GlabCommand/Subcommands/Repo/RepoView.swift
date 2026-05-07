import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct RepoView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Display a project's metadata.",
        aliases: ["show"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Optional positional override for the repo (same syntax as -R).")
    var positional: RepositoryReference?

    @Flag(name: [.customShort("w"), .long],
          help: "Open the project in your browser.")
    var web: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(
            flag: repo, positional: positional)
        let client = try await CommandContext.apiClient(host: target.host)
        let project: Project = try await client.get(
            "projects/\(target.encodedPath)")

        if web {
            try await Browser.open(project.webUrl)
            Stdio.print("Opening \(project.webUrl.absoluteString) in your browser.")
            return
        }
        if json {
            Stdio.print(try CodableOutput.prettyJSON(project))
            return
        }

        Stdio.print("\(ANSI.bold(project.pathWithNamespace))  \(ANSI.dim("(#\(project.id))"))")
        Stdio.print("name: \(project.name)")
        if let d = project.description, !d.isEmpty { Stdio.print("description: \(d)") }
        Stdio.print("visibility: \(project.visibility)")
        if let archived = project.archived, archived {
            Stdio.print("\(ANSI.yellow("⚠")) archived")
        }
        if let branch = project.defaultBranch { Stdio.print("default branch: \(branch)") }
        if let stars = project.starCount { Stdio.print("stars: \(stars)") }
        if let forks = project.forksCount { Stdio.print("forks: \(forks)") }
        if let open = project.openIssuesCount { Stdio.print("open issues: \(open)") }
        Stdio.print("urls:")
        Stdio.print("  web:  \(project.webUrl.absoluteString)")
        if let http = project.httpUrlToRepo { Stdio.print("  http: \(http.absoluteString)") }
        if let ssh = project.sshUrlToRepo { Stdio.print("  ssh:  \(ssh.absoluteString)") }
    }
}
