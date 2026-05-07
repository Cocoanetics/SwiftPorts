import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

/// `git reflog` (alias for `git reflog show`). Lists every change to
/// a ref with `<sha7> HEAD@{N}: <message>` per entry.
struct Reflog: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reflog",
        abstract: "Show the per-ref change log."
    )

    @Argument(help: "Ref name. Defaults to HEAD.")
    var ref: String = "HEAD"

    func run() async throws {
        let entries = try await CommandContext.gitClient().reflog(refName: ref)
        let stdout = Stdio.stdout
        for (idx, entry) in entries.enumerated() {
            // Real git's format: `<sha7> HEAD@{N}: <message>`.
            let short = String(entry.newSHA.prefix(7))
            stdout.write(Data("\(short) \(ref)@{\(idx)}: \(entry.message)\n".utf8))
        }
    }
}
