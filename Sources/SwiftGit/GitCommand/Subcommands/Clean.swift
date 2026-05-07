import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

/// `git clean` removes untracked working-tree files. We use our own
/// status walker to enumerate untracked entries, then file-system
/// delete them. Real git's `-d` recurses into untracked directories;
/// libgit2's status with RECURSE_UNTRACKED_DIRS already does that for
/// us, so the flag is mostly for parity.
struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove untracked files from the working tree."
    )

    @Flag(name: [.customShort("f"), .customLong("force")],
          help: "Required to actually delete (real git's safety gate).")
    var force: Bool = false

    @Flag(name: [.customShort("n"), .customLong("dry-run")],
          help: "Print what would be removed without actually removing.")
    var dryRun: Bool = false

    @Flag(name: [.customShort("d")],
          help: "Recurse into untracked directories (default behaviour for us).")
    var recurse: Bool = false

    @Argument(help: "Restrict to these paths.")
    var paths: [String] = []

    func validate() throws {
        if !force && !dryRun {
            throw ValidationError("clean.requireForce defaults to true; use -f or -n")
        }
    }

    func run() async throws {
        let client = CommandContext.gitClient()
        let report = try await client.status()

        let cwd = CommandContext.currentDirectory
        let fm = FileManager.default

        for entry in report.untrackedEntries {
            // Pathspec filter — keep only entries that match if the
            // user passed paths.
            if !paths.isEmpty,
               !paths.contains(where: { entry.path == $0
                   || entry.path.hasPrefix("\($0)/") }) {
                continue
            }
            let abs = cwd.appendingPathComponent(entry.path)
            // Real git prints a per-file `Removing <path>` line.
            Stdio.print("Removing \(entry.path)")
            if !dryRun {
                try? fm.removeItem(at: abs)
            }
        }
        _ = recurse
    }
}
