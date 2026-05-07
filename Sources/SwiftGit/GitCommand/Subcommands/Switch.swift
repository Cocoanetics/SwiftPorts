import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

/// `git switch` is real git's modern replacement for `git checkout`'s
/// branch-switching role. We map directly onto our existing checkout
/// machinery — the difference is purely UX clarity.
struct Switch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch branches."
    )

    @Option(name: [.customShort("c"), .customLong("create")],
            help: "Create the new branch and switch to it.")
    var create: String?

    @Option(name: [.customShort("C"), .customLong("force-create")],
            help: "Create or reset (force) the new branch.")
    var forceCreate: String?

    @Argument(help: "Branch (or start-point when used with -c/-C).")
    var ref: String?

    func validate() throws {
        if create != nil && forceCreate != nil {
            throw ValidationError("-c and -C are mutually exclusive")
        }
        if create == nil && forceCreate == nil && ref == nil {
            throw ValidationError("missing branch name")
        }
    }

    func run() async throws {
        let client = CommandContext.gitClient()

        if let name = create ?? forceCreate {
            let force = (forceCreate != nil)
            let startPoint = ref ?? "HEAD"
            do {
                let outcome = try await client.checkoutNewBranch(
                    name: name, startPoint: startPoint, force: force)
                switch outcome {
                case .createdNew(let n):
                    Stdio.print("Switched to a new branch '\(n)'")
                case .resetExisting(let n):
                    Stdio.print("Reset branch '\(n)'")
                }
            } catch let err as Libgit2Error
                where err.message.contains("already exists") {
                throw CLIError.stderr(
                    "fatal: a branch named '\(name)' already exists",
                    exitCode: 128)
            }
            return
        }

        guard let ref else {
            throw CLIError.stderr("fatal: missing branch", exitCode: 128)
        }
        let priorBranch = try await client.currentBranch()
        if priorBranch == ref {
            Stdio.print("Already on '\(ref)'")
            return
        }
        try await client.checkout(ref: ref)
        if let after = try? await client.currentBranch(), after == ref {
            Stdio.print("Switched to branch '\(ref)'")
        } else {
            Stdio.print("Note: switching to '\(ref)'.")
        }
    }
}
