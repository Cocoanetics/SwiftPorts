import ArgumentParser
import ShellKit
import Foundation
import SwiftGit

struct Show: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show various types of objects (commits, tags and blobs)."
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

        // Resolve the object first; blobs are emitted without formatting.
        let sha: String
        do {
            sha = try await client.resolveOID(target)
        } catch {
            if let colon = target.firstIndex(of: ":"), colon != target.startIndex {
                let revision = String(target[..<colon])
                let path = String(target[target.index(after: colon)...])
                guard (try? await client.resolveOID(revision + "^{tree}")) != nil else {
                    throw CLIError.stderr("fatal: invalid object name '\(revision)'.", exitCode: 128)
                }
                let url = Shell.resolve(path)
                try await Shell.authorize(url)
                let reason = FileManager.default.fileExists(atPath: url.path)
                    ? "exists on disk, but not in" : "does not exist in"
                throw CLIError.stderr("fatal: path '\(path)' \(reason) '\(revision)'", exitCode: 128)
            }
            throw CLIError.stderr(
                "fatal: ambiguous argument '\(target)': unknown revision or path not in the working tree.\n"
                    + "Use '--' to separate paths from revisions, like this:\n"
                    + "'git <command> [<revision>...] -- [<file>...]'",
                exitCode: 128)
        }

        let stdout = Shell.current.stdout

        if try await client.objectMetadata(of: sha).kind == .blob {
            stdout.write(try await client.catFileBlob(sha))
            return
        }

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
            let lines = try await Log.showSignatureLines(
                try await client.commitSignatureCheck(entry.sha), commit: entry.sha, walked: false, client: client)
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
