import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Describe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe",
        abstract: "Show the most recent tag reachable from a commit."
    )

    @Flag(name: .long, help: "Match lightweight tags too (not just annotated).")
    var tags: Bool = false

    @Flag(name: .long, help: "Append `-dirty` if the working tree differs from HEAD.")
    var dirty: Bool = false

    @Option(name: .long, help: "Number of hex chars in the SHA suffix (0 to suppress).")
    var abbrev: Int = 7

    @Argument(help: "Commit-ish to describe. Defaults to HEAD.")
    var committish: String = "HEAD"

    func run() async throws {
        let client = CommandContext.gitClient()
        let result = try await client.describe(
            committish: committish, tags: tags,
            abbrev: abbrev, dirty: dirty)
        Stdio.print(result)
    }
}
