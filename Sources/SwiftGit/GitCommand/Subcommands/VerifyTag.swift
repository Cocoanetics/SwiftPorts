import ArgumentParser
import ShellKit
import Foundation
import SwiftGit

struct VerifyTag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-tag",
        abstract: "Check the GPG signature of tags."
    )

    @Flag(name: [.customShort("v"), .customLong("verbose")],
          help: "Print the tag contents.")
    var verbose: Bool = false

    @Flag(name: .customLong("raw"),
          help: "Print the raw gpg status output.")
    var raw: Bool = false

    @Argument(help: "Tags to verify.")
    var tags: [String] = []

    func validate() throws {
        if tags.isEmpty { throw ValidationError("Missing expected argument '<tag> ...'") }
    }

    func run() async throws {
        try await Self.verify(tags, inTagNamespace: false, verbose: verbose, raw: raw)
    }

    /// git's `gpg_verify_tag` for each of `names`, what it finds said as
    /// git says it: the tag's contents with `verbose`, then the program's
    /// diagnostics (its raw status lines with `raw`) on stderr. Every tag
    /// is tried; any that doesn't verify fails the command.
    static func verify(_ names: [String], inTagNamespace: Bool, verbose: Bool, raw: Bool) async throws {
        let client = CommandContext.gitClient()
        let stdout = Shell.current.stdout, stderr = Shell.current.stderr
        var failed = false
        for name in names {
            switch try await client.verifyTag(name, inTagNamespace: inTagNamespace) {
            case .notFound:
                stderr.write("error: tag '\(name)' not found.\n")
            case .notATag(let type):
                stderr.write("error: \(name): cannot verify a non-tag object of type \(type).\n")
            case .unsigned(let object):
                if verbose { stdout.write(object) }
                stderr.write("error: no signature found\n")
            case .checked(_, let check):
                if verbose { stdout.write(check.payload) }
                if let text = raw ? check.status : check.output { stderr.write(text) }
                if check.succeeded { continue }
            }
            failed = true
        }
        if failed { throw CLIError.stderr([], exitCode: 1) }
    }
}
