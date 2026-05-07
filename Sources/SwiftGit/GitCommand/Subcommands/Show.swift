import ArgumentParser
import Sandbox
import Foundation
import SwiftGit

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show various types of objects (commits and tags today)."
    )

    @Argument(help: "Object to show. Defaults to HEAD.")
    var spec: String?

    func run() async throws {
        let client = CommandContext.gitClient()
        let target = spec ?? "HEAD"

        // Resolve the object first. We support commits + annotated
        // tags (real git also supports trees, blobs — those need
        // separate formatters; defer to a future patch).
        let sha: String
        do {
            sha = try await client.resolveOID(target)
        } catch {
            throw CLIError.stderr(
                "fatal: ambiguous argument '\(target)': unknown revision or path not in the working tree.",
                exitCode: 128)
        }

        let stdout = Stdio.stdout

        // If the spec resolves directly to an annotated tag, emit the
        // tag block then fall through to its target commit.
        let entries = try await client.tagDetails()
        if let tag = entries.first(where: { $0.sha == sha && $0.isAnnotated }) {
            stdout.write(Data("tag \(tag.name)\n".utf8))
            // Tagger + Date + message — pulled from libgit2 by tagDetails.
            // We don't currently surface tagger here; this is a small gap.
            // Print message body.
            stdout.write(Data("\n\(tag.summary)\n".utf8))
            // Then the target commit.
            try await showCommit(sha: tag.targetSHA, client: client, stdout: stdout)
            return
        }

        try await showCommit(sha: sha, client: client, stdout: stdout)
    }

    /// One-commit `defaultFormat` block + unified diff against parent.
    private func showCommit(
        sha: String, client: SwiftGit.GitClient, stdout: FileHandle
    ) async throws {
        let entries = try await client.log(LogQuery(starts: [sha], maxCount: 1))
        guard let entry = entries.first else { return }
        stdout.write(Data(entry.defaultFormat().utf8))

        // Diff: against first parent, or against empty for root commits.
        if let parent = entry.parentSHAs.first {
            let diff = try await client.diff(
                .commitVsCommit(parent, entry.sha), format: .patch)
            if !diff.isEmpty {
                stdout.write(Data("\n".utf8))
                stdout.write(Data(diff.utf8))
            }
        }
    }
}
