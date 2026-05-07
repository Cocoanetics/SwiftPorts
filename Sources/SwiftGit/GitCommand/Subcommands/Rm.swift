import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Rm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove files from the working tree and the index."
    )

    @Flag(name: .customLong("cached"),
          help: "Remove from index only; leave the working tree alone.")
    var cached: Bool = false

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: "Override safety checks.")
    var force: Bool = false

    @Argument(help: "Paths to remove.")
    var paths: [String]

    func run() async throws {
        try await CommandContext.gitClient().remove(
            paths: paths, keepWorktree: cached, force: force)
        // Match real-git's per-file `rm '<path>'` confirmation lines.
        for p in paths { Stdio.print("rm '\(p)'") }
    }
}
