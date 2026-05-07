import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct RepoDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a repository.",
        discussion: """
        Requires the `delete_repo` OAuth scope, which is not in the
        default scope set. If your token doesn't have it:

          gh auth refresh -h github.com -s delete_repo
        """
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Flag(name: [.short, .customLong("yes")], help: "Skip confirmation prompt.")
    var skipPrompt: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        if !skipPrompt {
            Stdio.stderr.write(Data(
                "\(ANSI.red("Permanently delete")) \(target.slug)? Type the repo name to confirm: ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard line == target.slug || line == target.name else {
                Stdio.stderr.write(Data("Aborted (input did not match).\n".utf8))
                throw ExitCode(1)
            }
        }
        let client = try await CommandContext.apiClient()
        try await client.delete("repos/\(target.slug)")
        Stdio.print("\(ANSI.green("✓")) Deleted \(target.slug)")
    }
}
