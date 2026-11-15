import ArgumentParser
import ShellKit
import Foundation
import SwiftGit

struct VerifyCommit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-commit",
        abstract: "Check the GPG signature of commits."
    )

    @Flag(name: [.customShort("v"), .customLong("verbose")],
          help: "Print the contents of the commit object before validating it.")
    var verbose: Bool = false

    @Flag(name: .customLong("raw"),
          help: "Print the raw gpg status output.")
    var raw: Bool = false

    @Argument(help: "Commits to verify.")
    var commits: [String] = []

    func validate() throws {
        if commits.isEmpty { throw ValidationError("Missing expected argument '<commit> ...'") }
    }

    /// git's `verify_commit` for each commit, what it finds said as git
    /// says it: the signed payload with `verbose`, then the program's
    /// diagnostics (its raw status lines with `raw`) on stderr. An
    /// unsigned commit says nothing and fails. Every commit is tried; any
    /// that doesn't verify fails the command.
    func run() async throws {
        let client = CommandContext.gitClient()
        let stdout = Shell.current.stdout, stderr = Shell.current.stderr
        var failed = false
        for name in commits {
            let verification: SwiftGit.GitClient.CommitVerification
            do {
                verification = try await client.verifyCommit(name)
            } catch let error as Libgit2Error where error.message.hasPrefix("unsupported value for gpg.") {
                throw CLIError.stderr("fatal: \(error.message)", exitCode: 128)
            }
            switch verification {
            case .notFound:
                stderr.write("error: commit '\(name)' not found.\n")
            case .notACommit(let type):
                stderr.write("error: \(name): cannot verify a non-commit object of type \(type).\n")
            case .unsigned:
                break
            case .checked(let check):
                if verbose { stdout.write(check.payload) }
                if let text = raw ? check.status : check.output { stderr.write(text) }
                if check.succeeded { continue }
            }
            failed = true
        }
        if failed { throw CLIError.stderr([], exitCode: 1) }
    }
}
