import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct LsFiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls-files",
        abstract: "Show information about files in the index."
    )

    func run() async throws {
        let paths = try await CommandContext.gitClient().indexedPaths()
        for path in paths { Stdio.print(path) }
    }
}
