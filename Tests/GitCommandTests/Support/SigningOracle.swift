// What the signing suites share: the system `git` and `ssh-keygen` run in
// an isolated host as the oracle, ours run in a shell over the same
// repository, and ssh keys and repositories to sign with.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
@testable import GitCommand

let canSignWithSSHKeygen = FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")

/// A suite comparing ours with the system `git` over signed objects.
protocol SigningOracle {
    var host: IsolatedGitHost { get }
}

/// A command the oracle ran that failed.
struct SigningOracleFailure: Error, CustomStringConvertible {
    let description: String
}

extension SigningOracle {

    /// Fixed dates, so ours and git's objects can be compared by id.
    static var dates: [String: String] {
        ["GIT_AUTHOR_DATE": "1700000000 +0000", "GIT_COMMITTER_DATE": "1700000000 +0000"]
    }

    @discardableResult
    func run(
        _ executable: String, _ args: [String], in dir: URL, environment: [String: String] = [:]
    ) throws -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + args
        process.currentDirectoryURL = dir
        host.isolate(process)
        process.environment?["SSH_AUTH_SOCK"] = nil
        process.environment?.merge(Self.dates.merging(environment) { _, new in new }) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (output, message, process.terminationStatus)
    }

    @discardableResult
    func systemGit(_ args: [String], in dir: URL) throws -> String {
        let result = try run("git", args, in: dir)
        guard result.status == 0 else {
            throw SigningOracleFailure(description: "git \(args.joined(separator: " ")): \(result.err)")
        }
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ours, in a shell over `dir` with the isolated host's config and
    /// `environment` on top, its stdout, its stderr and git's last words,
    /// and the status it exits with.
    func git(
        _ args: [String], in dir: URL, environment: [String: String] = [:],
        launcher: (any ProcessLauncher)? = nil, commands: [any Command] = []
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(
            stdout: out, stderr: err,
            environment: host.environment(Self.dates.merging(environment) { _, new in new },
                                          workingDirectory: dir.path),
            commands: Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) }),
            processLauncher: launcher)
        shell.sandbox = host.sandbox
        var failure: (any CommandFailure)?
        do {
            try await shell.withCurrent {
                let parsed = try GitCommand.parseAsRoot(GitCommand.preprocess(args))
                var command = try #require(parsed as? AsyncParsableCommand)
                try await command.run()
            }
        } catch let error as any CommandFailure {
            failure = error
        }
        out.finish()
        err.finish()
        let printed = await err.readAllString() + (failure?.diagnostic ?? "")
        return (await out.readAllString(), printed, failure.map { Int32($0.exitStatus.code) } ?? 0)
    }

    /// A repository `name` under `root` with one commit, set up to sign
    /// with ssh key `key` (a path, or `nil` for none).
    func makeRepository(_ name: String, in root: URL, key: String?) throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try systemGit(["init", "-q", "-b", "main"], in: repo)
        try systemGit(["config", "user.name", "Test"], in: repo)
        try systemGit(["config", "user.email", "test@example.com"], in: repo)
        try systemGit(["config", "gpg.format", "ssh"], in: repo)
        if let key { try systemGit(["config", "user.signingkey", key], in: repo) }
        try Data("a\n".utf8).write(to: repo.appendingPathComponent("a"))
        try systemGit(["add", "."], in: repo)
        try systemGit(["commit", "-q", "-m", "a"], in: repo)
        return repo
    }

    func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Signing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An ed25519 key pair `name` in `root`, and an allowed signers file
    /// trusting it for `test@example.com`.
    func makeKey(_ name: String, in root: URL) throws -> (key: String, allowed: String) {
        let result = try run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", name, "-f", name], in: root)
        guard result.status == 0 else { throw SigningOracleFailure(description: result.err) }
        let publicKey = try String(contentsOf: root.appendingPathComponent(name + ".pub"), encoding: .utf8)
        let allowed = root.appendingPathComponent("allowed-" + name)
        try "test@example.com \(publicKey)".write(to: allowed, atomically: true, encoding: .utf8)
        return (root.appendingPathComponent(name).path, allowed.path)
    }

    /// A commit written by the system git from `object`, the text of one
    /// (`git hash-object -t commit -w --literally`).
    func writeCommit(_ object: String, in repo: URL) throws -> String {
        let file = repo.appendingPathComponent(".git/crafted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try object.write(to: file, atomically: true, encoding: .utf8)
        return try systemGit(["hash-object", "-t", "commit", "-w", "--literally", file.path], in: repo)
    }
}
#endif
