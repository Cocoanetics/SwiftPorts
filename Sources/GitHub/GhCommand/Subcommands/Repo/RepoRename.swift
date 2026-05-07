import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct RepoRename: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a repository."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "New name (just the name, not OWNER/NAME).")
    var newName: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let updated: Repository = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)",
            body: RepoUpdateRequest(name: newName))
        Stdio.print("\(ANSI.green("✓")) Renamed \(target.slug) → \(updated.fullName)")
    }
}
