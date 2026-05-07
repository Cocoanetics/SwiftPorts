import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct RepoArchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Archive a project (read-only)."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Optional positional override for the repo.")
    var positional: RepositoryReference?

    private struct Empty: Encodable {}

    func run() async throws {
        let target = try await CommandContext.resolveRepo(
            flag: repo, positional: positional)
        let client = try await CommandContext.apiClient(host: target.host)
        let project: Project = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/archive",
            body: Empty())
        Stdio.print("\(ANSI.yellow("⚠")) Archived \(project.pathWithNamespace)")
    }
}

struct RepoUnarchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unarchive",
        abstract: "Unarchive a project."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Optional positional override for the repo.")
    var positional: RepositoryReference?

    private struct Empty: Encodable {}

    func run() async throws {
        let target = try await CommandContext.resolveRepo(
            flag: repo, positional: positional)
        let client = try await CommandContext.apiClient(host: target.host)
        let project: Project = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/unarchive",
            body: Empty())
        Stdio.print("\(ANSI.green("✓")) Unarchived \(project.pathWithNamespace)")
    }
}
