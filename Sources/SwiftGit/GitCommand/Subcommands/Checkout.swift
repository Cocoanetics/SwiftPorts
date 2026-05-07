import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Checkout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkout",
        abstract: "Switch branches or restore working-tree files.",
        discussion: """
            Forms supported:
              git checkout <ref>                  switch to branch / detach to ref
              git checkout -b <new> [<start>]     create branch + switch
              git checkout -B <new> [<start>]     force-create / reset + switch
              git checkout -- <paths>             restore <paths> from index
              git checkout <ref> -- <paths>       restore <paths> from <ref>
            """
    )

    @Option(name: .customShort("b"),
            help: "Create a new branch and switch to it.")
    var newBranch: String?

    @Option(name: .customShort("B"),
            help: "Create or reset (force) a branch and switch to it.")
    var forceBranch: String?

    @Argument(parsing: .captureForPassthrough,
              help: "Optional <ref> / <start-point>, then `-- <paths>`.")
    var rest: [String] = []

    func validate() throws {
        if newBranch != nil && forceBranch != nil {
            throw ValidationError("-b and -B are mutually exclusive")
        }
    }

    func run() async throws {
        let (refs, paths) = Self.split(rest)
        let client = CommandContext.gitClient()

        // -b / -B paths.
        if let name = newBranch ?? forceBranch {
            let force = (forceBranch != nil)
            let startPoint = refs.first ?? "HEAD"
            do {
                let outcome = try await client.checkoutNewBranch(
                    name: name, startPoint: startPoint, force: force)
                switch outcome {
                case .createdNew(let n):
                    Stdio.print("Switched to a new branch '\(n)'")
                case .resetExisting(let n):
                    Stdio.print("Switched to and reset branch '\(n)'")
                }
            } catch let err as Libgit2Error
                where err.message.contains("already exists") {
                throw CLIError.stderr(
                    "fatal: a branch named '\(name)' already exists",
                    exitCode: 128)
            }
            return
        }

        // Path-restore forms.
        if !paths.isEmpty {
            if let ref = refs.first {
                try await client.checkoutPaths(paths, from: ref)
            } else {
                try await client.checkoutPaths(paths)
            }
            return
        }

        // Bare-ref form (the original implementation).
        guard let ref = refs.first else {
            throw CLIError.stderr(
                "fatal: missing argument: <ref>", exitCode: 128)
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

    /// Split positional args at `--` into (refs, paths). Without `--`,
    /// every positional is treated as a ref.
    static func split(_ args: [String]) -> (refs: [String], paths: [String]) {
        if let sep = args.firstIndex(of: "--") {
            return (Array(args[..<sep]), Array(args[(sep + 1)...]))
        }
        return (args, [])
    }
}
