import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the working-tree status."
    )

    @Flag(name: [.customShort("s"), .customLong("short")],
          help: "One-line-per-file `XY <path>` format.")
    var short: Bool = false

    @Flag(name: .customLong("porcelain"),
          help: "Stable machine-readable format (alias for --short).")
    var porcelain: Bool = false

    @Flag(name: [.customShort("b"), .customLong("branch")],
          help: "Show the branch in the header (always shown in verbose mode).")
    var branch: Bool = false

    func run() async throws {
        let report = try await CommandContext.gitClient().status()

        // --short and --porcelain produce identical output for our
        // subset (we don't implement the `=v2` variant).
        if short || porcelain {
            let out = report.shortFormat(branchHeader: branch)
            Stdio.stdout.write(Data(out.utf8))
            return
        }

        // Verbose form.
        let out = report.verboseFormat()
        Stdio.stdout.write(Data(out.utf8))
    }
}
