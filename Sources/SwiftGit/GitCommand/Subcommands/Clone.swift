import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

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

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress progress output.")
    var quiet: Bool = false

    func validate() throws {
        if let depth, depth <= 0 {
            throw ValidationError("--depth must be a positive integer")
        }
    }

    func run() async throws {
        guard !url.isEmpty else {
            throw CLIError.stderr("fatal: repository '' does not exist", exitCode: 128)
        }
        let dest = directory.map { Shell.resolve($0) }
        guard var displayName = directory ?? SwiftGit.GitClient.humanishName(of: url) else {
            throw CLIError.stderr([
                "fatal: No directory name could be guessed.",
                "Please specify a directory on the command line"
            ], exitCode: 128)
        }
        // git names the directory without trailing separators.
        #if os(Windows)
        let separators: Set<Character> = ["/", "\\"]
        #else
        let separators: Set<Character> = ["/"]
        #endif
        while displayName.count > 1, let last = displayName.last, separators.contains(last) {
            displayName.removeLast()
        }

        // Real git emits this header to stderr before the network work
        // starts; we follow the same convention so callers piping the
        // CLI to a log can grep it consistently.
        let stderr = Shell.current.stderr
        if !quiet {
            stderr.write(Data("Cloning into '\(displayName)'...\n".utf8))
        }

        // The remote as typed: a `URL` can't always hold a scp-style one.
        do {
            try await CommandContext.gitClient(quiet: quiet).clone(
                remote: url,
                directory: dest,
                depth: depth,
                singleBranch: singleBranch || depth != nil,
                branch: branch)
        } catch let error as NoRemoteHelperError {
            throw CLIError(error)
        }

        // A local clone has no transfer progress (libgit2's local
        // transport skips it), so close out with `done.\n`, as real git
        // does. A network clone already ended on `Receiving objects: …,
        // done.`.
        if !quiet, Self.isLocal(url) {
            stderr.write(Data("done.\n".utf8))
        }
    }

    /// Whether `remote` is a local path, which git clones by copying
    /// objects (ending on `done.`): not a URL — a `file://` URL goes
    /// through the regular transport, like any other — and not a
    /// scp-style `host:path`, which has a colon before any slash
    /// (`/srv/team@host/repo:copy.git` is a path).
    static func isLocal(_ remote: String) -> Bool {
        !SwiftGit.GitClient.isURLOrSCPLike(remote)
    }
}
