import ArgumentParser
import ShellKit
import Foundation
import SwiftGit

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show various types of objects (commits and tags today)."
    )

    @Flag(name: .customLong("show-signature"), inversion: .prefixedNo,
          help: "Check a signed commit's signature and show the result (log.showSignature).")
    var showSignature: Bool?

    @Argument(help: "Object to show. Defaults to HEAD.")
    var spec: String?

    func run() async throws {
        let client = CommandContext.gitClient()
        let target = spec ?? "HEAD"
        let showSignatures = try await Log.pullShowSignature([], flag: showSignature, client: client).show

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

        let stdout = Shell.current.stdout

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
            try await showCommit(sha: tag.targetSHA, client: client, stdout: stdout, signature: showSignatures)
            return
        }

        try await showCommit(sha: sha, client: client, stdout: stdout, signature: showSignatures)
    }

    /// One-commit `defaultFormat` block + unified diff against parent.
    private func showCommit(
        sha: String, client: SwiftGit.GitClient, stdout: OutputSink, signature: Bool
    ) async throws {
        let entries = try await client.log(LogQuery(starts: [sha], maxCount: 1))
        guard let entry = entries.first else { return }
        var block = entry.defaultFormat()
        // `--show-signature`: the signature's lines after `commit <sha>`.
        if signature, let header = block.firstIndex(of: "\n") {
            let lines = Log.signatureLines(try await client.commitSignatureCheck(entry.sha))
            block.insert(contentsOf: lines, at: block.index(after: header))
        }
        stdout.write(Data(block.utf8))

        // Diff: against first parent, or against the empty tree for
        // the root commit (every file appears as an addition, matching
        // real git's `show` output).
        let target: DiffTarget
        if let parent = entry.parentSHAs.first {
            target = .commitVsCommit(parent, entry.sha)
        } else {
            target = .emptyVsCommit(entry.sha)
        }
        let diff = try await client.diff(target, format: .patch)
        if !diff.isEmpty {
            stdout.write(Data("\n".utf8))
            stdout.write(Data(diff.utf8))
        }
    }
}
