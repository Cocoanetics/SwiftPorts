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
        if target.hasPrefix(":"), !target.hasPrefix(":/") {
            sha = try await resolveIndexBlob(target, client: client)
        } else {
            do {
                sha = try await client.resolveOID(target)
            } catch {
                if let colon = revisionPathSeparator(in: target), colon != target.startIndex {
                    let revision = String(target[..<colon])
                    let path = String(target[target.index(after: colon)...])
                    guard (try? await client.resolveOID(revision + "^{tree}")) != nil else {
                        throw CLIError.stderr("fatal: invalid object name '\(revision)'.", exitCode: 128)
                    }
                    let root = try await client.toplevel().map { URL(fileURLWithPath: $0, isDirectory: true) }
                        ?? client.workingDirectory
                    let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
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
        }

        let stdout = Shell.current.stdout

        if try await client.objectMetadata(of: sha).kind == .blob {
            stdout.write(try await client.catFileBlob(sha))
            return
        }

        // If the spec resolves directly to an annotated tag, emit the
        // tag block then fall through to its target object.
        let entries = try await client.tagDetails()
        if let tag = entries.first(where: { $0.sha == sha && $0.isAnnotated }) {
            stdout.write(Data("tag \(tag.name)\n".utf8))
            // Tagger + Date + message — pulled from libgit2 by tagDetails.
            // We don't currently surface tagger here; this is a small gap.
            // Print message body.
            stdout.write(Data("\n\(tag.summary)\n".utf8))
            if try await client.objectMetadata(of: tag.targetSHA).kind == .blob {
                stdout.write(try await client.catFileBlob(tag.targetSHA))
                return
            }
            // Otherwise, keep the existing commit formatter.
            try await showCommit(sha: tag.targetSHA, client: client, stdout: stdout, signature: showSignatures)
            return
        }

        try await showCommit(sha: sha, client: client, stdout: stdout, signature: showSignatures)
    }

    /// Match object-name.c: colons inside `@{...}` and `^{...}` belong to the revision.
    private func revisionPathSeparator(in target: String) -> String.Index? {
        var depth = 0
        var previous: Character?
        for index in target.indices {
            let character = target[index]
            if character == "{", previous == "@" || previous == "^" {
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
            } else if character == ":", depth == 0 {
                return index
            }
            previous = character
        }
        return nil
    }

    /// Index paths use stage zero unless an explicit `:0:` ... `:3:` is given.
    private func resolveIndexBlob(_ spec: String, client: SwiftGit.GitClient) async throws -> String {
        var path = String(spec.dropFirst())
        var stage = 0
        if path.count >= 2, let digit = path.first, ("0"..."3").contains(String(digit)),
           path[path.index(after: path.startIndex)] == ":" {
            stage = Int(String(digit)) ?? 0
            path = String(path.dropFirst(2))
        }
        let entries = try await client.indexedEntries().filter { $0.path == path }
        if let entry = entries.first(where: { $0.stage == stage }) { return entry.oid }
        if let entry = entries.first {
            throw CLIError.stderr(
                "fatal: path '\(path)' is in the index, but not at stage \(stage)\n"
                    + "hint: Did you mean ':\(entry.stage):\(path)'?", exitCode: 128)
        }
        let root = try await client.toplevel().map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? client.workingDirectory
        let url = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
        try await Shell.authorize(url)
        let reason = FileManager.default.fileExists(atPath: url.path)
            ? "exists on disk, but not in the index" : "does not exist (neither on disk nor in the index)"
        throw CLIError.stderr("fatal: path '\(path)' \(reason)", exitCode: 128)
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
