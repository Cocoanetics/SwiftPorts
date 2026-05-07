import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct RepoDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a GitLab project. Irreversible."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Optional positional override.")
    var positional: RepositoryReference?

    @Flag(name: [.customShort("y"), .customLong("yes")],
          help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(
            flag: repo, positional: positional)
        if !yes {
            Stdio.stderr.write(Data(
                "\(ANSI.red("⚠"))  About to delete \(ANSI.bold(target.fullPath)) on \(target.host ?? "default host"). This is irreversible.\nType the path again to confirm: ".utf8))
            guard let line = readLine(strippingNewline: true), line == target.fullPath else {
                throw RepoDeleteError.confirmationMismatch
            }
        }
        let client = try await CommandContext.apiClient(host: target.host)
        try await client.delete("projects/\(target.encodedPath)")
        Stdio.print("\(ANSI.green("✓")) Deleted \(target.fullPath).")
    }
}

enum RepoDeleteError: Error, LocalizedError {
    case confirmationMismatch
    var errorDescription: String? {
        "Confirmation didn't match the project path; nothing was deleted."
    }
}
