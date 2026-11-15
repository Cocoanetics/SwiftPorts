// Compare the message bytes, not object IDs or pretty-printed/trimmed log output.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
@testable import GitCommand

@Suite("git merge/pull raw message bytes")
struct GitCommandMergeMessageTests {
    private let host = IsolatedGitHost()
    private let environment = ["GIT_MERGE_AUTOEDIT": "no", "LC_ALL": "C"]

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private func run(_ executable: String, _ args: [String], in dir: URL) throws -> (Data, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + args
        process.currentDirectoryURL = dir
        host.isolate(process)
        process.environment?.merge(environment) { _, new in new }
        process.environment?["SSH_AUTH_SOCK"] = nil
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let diagnostic = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus <= 1 else {
            throw Failure(description: "\(executable) \(args): \(String(decoding: diagnostic, as: UTF8.self))")
        }
        return (data, process.terminationStatus)
    }

    @discardableResult
    private func systemGit(_ args: [String], in dir: URL) throws -> Data {
        let (data, status) = try run("git", args, in: dir)
        try #require(status == 0, "git \(args)")
        return data
    }

    private func git(_ args: [String], in dir: URL) async throws -> Int32 {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(stdout: out, stderr: err,
                          environment: host.environment(environment, workingDirectory: dir.path))
        shell.sandbox = host.sandbox
        defer { out.finish(); err.finish() }
        do {
            try await shell.withCurrent {
                let parsed = try GitCommand.parseAsRoot(GitCommand.preprocess(args))
                var command = try #require(parsed as? AsyncParsableCommand)
                try await command.run()
            }
        } catch let error as CLIError {
            return error.exitCode
        }
        return 0
    }

    private func root() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MergeMessage-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func commit(_ file: String, text: String, in dir: URL) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(file))
        try systemGit(["add", "."], in: dir)
        try systemGit(["commit", "-qm", file], in: dir)
    }

    /// Side and other are independent; main optionally conflicts with side.
    private func repository(in root: URL, conflict: Bool = false) throws -> URL {
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try systemGit(["init", "-q", "-b", "main"], in: repo)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com"),
                             ("commit.gpgsign", "false"), ("tag.gpgsign", "false")] {
            try systemGit(["config", key, value], in: repo)
        }
        try commit("base", text: "base\n", in: repo)
        try systemGit(["checkout", "-qb", "side"], in: repo)
        try commit(conflict ? "base" : "side", text: "side\n", in: repo)
        try systemGit(["tag", "-a", "--cleanup=verbatim", "ann", "-m",
                       "release\n\n  indented  \n\n\n# retained"], in: repo)
        try systemGit(["update-ref", "refs/remotes/origin/side", "HEAD"], in: repo)
        try systemGit(["checkout", "-qb", "other", "main"], in: repo)
        try commit("other", text: "other\n", in: repo)
        try systemGit(["checkout", "-q", "main"], in: repo)
        try commit(conflict ? "base" : "main", text: "main\n", in: repo)
        return repo
    }

    private func twin(of repo: URL) throws -> URL {
        let twin = repo.deletingLastPathComponent().appendingPathComponent("oracle")
        try FileManager.default.copyItem(at: repo, to: twin)
        return twin
    }

    private func message(in repo: URL) throws -> Data {
        let object = try systemGit(["cat-file", "commit", "HEAD"], in: repo)
        let separator = try #require(object.range(of: Data("\n\n".utf8)))
        return Data(object[separator.upperBound...])
    }

    private func compare(_ args: [String], in repo: URL, conflicts: Bool = false) async throws {
        let oracle = try twin(of: repo)
        let (_, expectedStatus) = try run("git", args, in: oracle)
        let status = try await git(args, in: repo)
        #expect(status == expectedStatus)
        try #require(status == (conflicts ? 1 : 0))
        let actual: Data, expected: Data
        if conflicts {
            actual = try Data(contentsOf: repo.appendingPathComponent(".git/MERGE_MSG"))
            expected = try Data(contentsOf: oracle.appendingPathComponent(".git/MERGE_MSG"))
        } else {
            actual = try message(in: repo)
            expected = try message(in: oracle)
        }
        let actualText = String(reflecting: String(decoding: actual, as: UTF8.self))
        let expectedText = String(reflecting: String(decoding: expected, as: UTF8.self))
        #expect(actual == expected, "actual: \(actualText) expected: \(expectedText)")
    }

    @Test("single-ref default title and terminal newline", arguments: ["main", "topic"])
    func defaultMessage(branch: String) async throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try repository(in: dir)
        if branch != "main" { try systemGit(["checkout", "-qb", branch], in: repo) }
        try await compare(["merge", "--no-ff", "side"], in: repo)
    }

    @Test("-m space cleanup preserves indentation and comments", arguments: [
        "x", "x\n\n\n", "  x  ", "\n\n  x  \n\n\n# retained  \n\n  body\t\n\n"
    ])
    func explicitMessage(text: String) async throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try repository(in: dir)
        try await compare(["merge", "--no-ff", "-m", text, "side"], in: repo)
    }

    @Test("remote-tracking branch, annotated tag and suppressDest", arguments: [
        ("origin/side", ""), ("side", "topic"), ("side", ""), ("ann", "topic")
    ])
    func generatedMessage(ref: String, suppress: String) async throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try repository(in: dir)
        try systemGit(["checkout", "-qb", "topic"], in: repo)
        try systemGit(["config", "merge.suppressDest", suppress], in: repo)
        try await compare(["merge", "--no-ff", ref], in: repo)
    }

    @Test("reduced and octopus heads clean messages once", arguments: [
        ["side", "side"], ["side", "other"]
    ])
    func multipleHeads(refs: [String]) async throws {
        for text in [String?.none, "  x  \n\n\n"] {
            let dir = try root()
            defer { try? FileManager.default.removeItem(at: dir) }
            let repo = try repository(in: dir)
            try await compare(["merge", "--no-ff"] + (text.map { ["-m", $0] } ?? []) + refs, in: repo)
        }
    }

    @Test("conflicted single/reduced merges preserve pre-cleanup MERGE_MSG", arguments: [
        "side", "side side"
    ])
    func conflictMessage(refs: String) async throws {
        for text in [String?.none, "x\n\n\n", "  x  "] {
            let dir = try root()
            defer { try? FileManager.default.removeItem(at: dir) }
            let repo = try repository(in: dir, conflict: true)
            try await compare(["merge"] + (text.map { ["-m", $0] } ?? [])
                              + refs.split(separator: " ").map(String.init), in: repo, conflicts: true)
        }
    }

    @Test("pull from a local remote, commit and conflict bytes", arguments: [false, true])
    func pullMessage(conflicts: Bool) async throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try repository(in: dir, conflict: conflicts)
        let remote = dir.appendingPathComponent("remote.git")
        try systemGit(["clone", "-q", "--bare", repo.path, remote.path], in: dir)
        try await compare(["pull", "--no-rebase", "--no-ff", remote.path, "side"],
                          in: repo, conflicts: conflicts)
    }

    @Test("pull reduced and octopus heads", arguments: [["side", "side"], ["side", "other"]])
    func pullMultipleHeads(refs: [String]) async throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try repository(in: dir)
        let remote = dir.appendingPathComponent("remote.git")
        try systemGit(["clone", "-q", "--bare", repo.path, remote.path], in: dir)
        try await compare(["pull", "--no-rebase", "--no-ff", remote.path] + refs, in: repo)
    }

    @Test("ssh-signed tag retains signature comments and final newline",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")))
    func signedTagMessage() async throws {
        let dir = try root()
        defer { try? FileManager.default.removeItem(at: dir) }
        let repo = try repository(in: dir)
        let key = dir.appendingPathComponent("key")
        let (_, status) = try run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", key.path], in: dir)
        try #require(status == 0)
        let publicKey = try String(contentsOf: dir.appendingPathComponent("key.pub"), encoding: .utf8)
        let allowed = dir.appendingPathComponent("allowed")
        try Data("test@example.com \(publicKey)".utf8).write(to: allowed)
        for (name, value) in [("gpg.format", "ssh"), ("user.signingkey", key.path),
                              ("gpg.ssh.allowedSignersFile", allowed.path)] {
            try systemGit(["config", name, value], in: repo)
        }
        try systemGit(["tag", "-s", "signed", "side", "-m", "release"], in: repo)
        try await compare(["merge", "--no-ff", "signed"], in: repo)
    }
}
#endif
