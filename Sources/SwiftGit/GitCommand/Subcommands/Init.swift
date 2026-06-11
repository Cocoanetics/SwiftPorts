import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

struct GitInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create an empty Git repository or reinitialize an existing one."
    )

    @Flag(name: .long, help: "Create a bare repository.")
    var bare: Bool = false

    @Option(name: [.customShort("b"), .customLong("initial-branch")],
            help: "Override the initial branch name (default: `master` unless `init.defaultBranch` is set).")
    var initialBranch: String?

    @Argument(help: "Directory to initialize. Defaults to the current directory.")
    var directory: String?

    func run() async throws {
        let target: URL
        if let directory {
            target = Shell.resolve(directory)
        } else {
            target = CommandContext.currentDirectory
        }
        let client = SwiftGit.GitClient(workingDirectory: target)
        let dest = try await client.initRepository(
            bare: bare, initialBranch: initialBranch, reinit: true)
        // Real git prints the absolute .git directory path. We mirror
        // the style: "Initialized empty Git repository in /path/.git/".
        // `dest` is the resolved HOST path; fold it back to the
        // script-visible spelling under a path-mapped sandbox (a
        // no-op otherwise).
        let suffix = bare ? "" : "/.git/"
        Shell.print("Initialized empty Git repository in "
            + Shell.displayPath(for: dest) + suffix)
    }
}
