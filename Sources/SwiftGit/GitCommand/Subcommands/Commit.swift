import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import SwiftGit

struct Commit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commit",
        abstract: "Stage all changes and create a new commit on HEAD."
    )

    @Option(name: [.customShort("m"), .customLong("message")],
            help: "Commit message.")
    var message: String

    @Option(name: .customLong("author"),
            help: "Override the commit author. Format: \"Name <email>\".")
    var author: String?

    @Flag(name: .customLong("allow-empty"),
          help: "Allow recording a commit that has the same tree as its parent.")
    var allowEmpty: Bool = false

    func run() async throws {
        let parsedAuthor = try author.map { try Self.parseAuthor($0) }
        let client = CommandContext.gitClient()

        let details: Libgit2CommitDetails
        do {
            details = try await client.commitDetailed(
                message: message,
                author: parsedAuthor,
                allowEmpty: allowEmpty)
        } catch let err as Libgit2Error
            where err.message.contains("nothing to commit") {
            // Mirror `git commit` on a clean tree.
            let branch = (try? await client.currentBranch()) ?? "HEAD"
            throw CLIError.stderr(
                ["On branch \(branch)", "nothing to commit, working tree clean"],
                exitCode: 1)
        }

        // [<branch> [(root-commit) ]<short>] <subject>
        let branchTag = details.branchName ?? "detached HEAD"
        let rootTag = details.isRoot ? " (root-commit)" : ""
        let subject = message.split(separator: "\n").first.map(String.init) ?? message
        Stdio.print("[\(branchTag)\(rootTag) \(details.shortSHA)] \(subject)")

        // " N file changed, X insertion(+), Y deletion(-)" with proper
        // singular/plural and the zero-clauses suppressed.
        var summary = " \(details.filesChanged) file\(details.filesChanged == 1 ? "" : "s") changed"
        if details.insertions > 0 {
            summary += ", \(details.insertions) insertion\(details.insertions == 1 ? "" : "s")(+)"
        }
        if details.deletions > 0 {
            summary += ", \(details.deletions) deletion\(details.deletions == 1 ? "" : "s")(-)"
        }
        Stdio.print(summary)

        // Per-file mode lines for additions and deletions, six-digit
        // octal mode just like real git.
        for file in details.addedFiles {
            Stdio.print(" create mode \(formatMode(file.mode)) \(file.path)")
        }
        for file in details.deletedFiles {
            Stdio.print(" delete mode \(formatMode(file.mode)) \(file.path)")
        }
    }

    private func formatMode(_ mode: UInt32) -> String {
        // Six-digit octal, e.g. 100644.
        String(mode, radix: 8)
    }

    /// Parse a `Name <email>` string into a ``GitSignature``. Tolerates
    /// trailing/leading whitespace.
    static func parseAuthor(_ input: String) throws -> GitSignature {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard let openIdx = trimmed.lastIndex(of: "<"),
              let closeIdx = trimmed.lastIndex(of: ">"),
              openIdx < closeIdx
        else {
            throw ValidationError(#"--author must be in the form "Name <email>""#)
        }
        let name = trimmed[..<openIdx].trimmingCharacters(in: .whitespaces)
        let email = String(trimmed[trimmed.index(after: openIdx)..<closeIdx])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !email.isEmpty else {
            throw ValidationError(#"--author must be in the form "Name <email>""#)
        }
        return GitSignature(name: name, email: email)
    }
}
