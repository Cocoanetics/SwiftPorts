import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct RepoArchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "archive",
        abstract: "Archive a repository (read-only)."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Flag(name: [.short, .customLong("yes")], help: "Skip confirmation prompt.")
    var skipPrompt: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        if !skipPrompt {
            Stdio.stderr.write(Data("Archive \(target.slug)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else { throw ExitCode(1) }
        }
        let client = try await CommandContext.apiClient()
        let updated: Repository = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)",
            body: RepoUpdateRequest(archived: true))
        Stdio.print("\(ANSI.green("✓")) Archived \(updated.fullName)")
    }
}

struct RepoUnarchive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unarchive",
        abstract: "Restore a repository from archived state."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let updated: Repository = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)",
            body: RepoUpdateRequest(archived: false))
        Stdio.print("\(ANSI.green("✓")) Unarchived \(updated.fullName)")
    }
}
