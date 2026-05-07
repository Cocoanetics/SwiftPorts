import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct GistDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a gist."
    )

    @Argument(help: "Gist ID.")
    var id: String

    @Flag(name: [.short, .customLong("yes")],
          help: "Skip confirmation prompt.")
    var skipPrompt: Bool = false

    func run() async throws {
        let client = try await CommandContext.apiClient()
        if !skipPrompt {
            Stdio.stderr.write(Data("Delete gist \(id)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                Stdio.print("Aborted.")
                throw ExitCode(1)
            }
        }
        try await client.delete("gists/\(id)")
        Stdio.print("✓ Deleted gist \(id)")
    }
}
