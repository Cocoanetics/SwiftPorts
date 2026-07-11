import ArgumentParser
import Foundation
import ShellKit

struct Clone: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone a repository into a new directory."
    )

    @Argument(help: "URL of the repository to clone.")
    var url: String

    @Argument(help: "Directory to clone into. Defaults to the URL's basename.")
    var directory: String?

    @Option(name: .customLong("depth"),
            help: "Create a shallow clone with a history truncated to N commits.")
    var depth: Int?

    @Flag(name: .customLong("single-branch"),
          help: "Clone only the selected branch's history.")
    var singleBranch: Bool = false

    @Option(name: [.customShort("b"), .customLong("branch")],
            help: "Branch to check out instead of the remote HEAD.")
    var branch: String?

    func validate() throws {
        if let depth, depth <= 0 {
            throw ValidationError("--depth must be a positive integer")
        }
    }

    func run() async throws {
        guard let parsed = URL(string: url) else {
            throw CLIError.stderr("fatal: '\(url)' is not a valid URL", exitCode: 128)
        }
        let dest = directory.map { Shell.resolve($0) }
        let displayName = directory ?? defaultDirName(for: parsed)

        // Real git emits this header to stderr before the network work
        // starts; we follow the same convention so callers piping the
        // CLI to a log can grep it consistently.
        let stderr = Shell.current.stderr
        stderr.write(Data("Cloning into '\(displayName)'...\n".utf8))

        try await CommandContext.gitClient().clone(
            url: parsed,
            directory: dest,
            depth: depth,
            singleBranch: singleBranch || depth != nil,
            branch: branch)

        // Local file:// clones don't emit transfer progress (libgit2's
        // local transport skips it), so we close out with `done.\n` —
        // that's what real git prints when there's nothing to transfer.
        stderr.write(Data("done.\n".utf8))
    }

    private func defaultDirName(for url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty ? "repo" : last
    }
}
