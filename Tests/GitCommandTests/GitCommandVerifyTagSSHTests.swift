// SSH tag signatures (#142) through `git tag -v`, `git verify-tag` and the
// merge message, each compared with the system `git` as the oracle where
// `ssh-keygen` exists. Keys are generated per test, and HOME, the global
// config and ssh-agent are never the host's.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
@testable import SwiftGit
@testable import GitCommand

private let hasSSHKeygen = FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")

@Suite("git tag -v / verify-tag / merge: SSH signatures")
struct GitCommandVerifyTagSSHTests {

    private let host = IsolatedGitHost()

    private static let noAllowedSigners =
        "error: gpg.ssh.allowedSignersFile needs to be configured and exist for ssh signature verification\n"

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @discardableResult
    private func run(
        _ executable: String, _ args: [String], in dir: URL
    ) throws -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + args
        process.currentDirectoryURL = dir
        host.isolate(process)
        process.environment?["SSH_AUTH_SOCK"] = nil
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
    private func systemGit(_ args: [String], in dir: URL) throws -> String {
        let result = try run("git", args, in: dir)
        guard result.status == 0 else {
            throw Failure(description: "git \(args.joined(separator: " ")): \(result.err)")
        }
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A generated ed25519 key pair `name` in `dir`.
    private func makeKey(_ name: String, in dir: URL) throws {
        let result = try run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", name, "-f", name], in: dir)
        guard result.status == 0 else { throw Failure(description: result.err) }
    }

    private func publicKey(_ name: String, in dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(name + ".pub"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Fixture {
        var repo: URL
        var keys: URL
    }

    /// `main` and branches `one` and `two` with tags `v1` (signed by
    /// `alice`, who is allowed), `v2` (signed by `mallory`, who is not).
    /// The committer identity is the repository's own config.
    private func makeFixture(allowed: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerifySSH-\(UUID().uuidString)")
        let keys = root.appendingPathComponent("keys"), repo = root.appendingPathComponent("repo")
        for dir in [keys, repo] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        try makeKey("alice", in: keys)
        try makeKey("mallory", in: keys)
        try "alice@example.com \(try publicKey("alice", in: keys))\n"
            .write(to: keys.appendingPathComponent("allowed"), atomically: true, encoding: .utf8)
        try systemGit(["init", "-q", "-b", "main"], in: repo)
        try systemGit(["config", "user.name", "Test"], in: repo)
        try systemGit(["config", "user.email", "test@example.com"], in: repo)
        try systemGit(["config", "gpg.format", "ssh"], in: repo)
        if allowed {
            let allowedFile = keys.appendingPathComponent("allowed").path
            try systemGit(["config", "gpg.ssh.allowedSignersFile", allowedFile], in: repo)
        }
        func commit(_ file: String) throws {
            try Data("\(file)\n".utf8).write(to: repo.appendingPathComponent(file))
            try systemGit(["add", "."], in: repo)
            try systemGit(["commit", "-q", "-m", file], in: repo)
        }
        try commit("base")
        for (branch, tag, key) in [("one", "v1", "alice"), ("two", "v2", "mallory")] {
            try systemGit(["checkout", "-q", "-b", branch, "main"], in: repo)
            try commit(branch)
            try systemGit(["-c", "user.signingkey=\(keys.appendingPathComponent(key).path)",
                           "tag", "-s", "-m", "release \(tag)", tag], in: repo)
        }
        try systemGit(["checkout", "-q", "main"], in: repo)
        try commit("main")
        return Fixture(repo: repo, keys: keys)
    }

    private func git(
        _ args: [String], in dir: URL, launcher: (any ProcessLauncher)? = nil
    ) async throws -> (stdout: String, stderr: String, status: Int32) {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(stdout: out, stderr: err, environment: host.environment(workingDirectory: dir.path),
                          processLauncher: launcher)
        shell.sandbox = host.sandbox
        var failure: CLIError?
        do {
            try await shell.withCurrent {
                let parsed = try GitCommand.parseAsRoot(GitCommand.preprocess(args))
                var command = try #require(parsed as? AsyncParsableCommand)
                try await command.run()
            }
        } catch let error as CLIError {
            failure = error
        }
        out.finish()
        err.finish()
        let printed = await err.readAllString() + (failure?.lines.map { $0 + "\n" }.joined() ?? "")
        return (await out.readAllString(), printed, failure?.exitCode ?? 0)
    }

    /// Ours and the system git's result for `args` must be the same.
    private func expectParity(
        _ args: [String], in repo: URL, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let ours = try await git(args, in: repo)
        let theirs = try run("git", args, in: repo)
        #expect(ours.stdout == theirs.out, "stdout of \(args)", sourceLocation: sourceLocation)
        #expect(ours.stderr == theirs.err, "stderr of \(args)", sourceLocation: sourceLocation)
        #expect(ours.status == theirs.status, "status of \(args)", sourceLocation: sourceLocation)
    }

    @Test("an allowed signer verifies; an unknown one fails, both as git does", .enabled(if: hasSSHKeygen))
    func allowedAndUnknownSigner() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.deletingLastPathComponent()) }
        let good = try await git(["verify-tag", "v1"], in: fixture.repo)
        #expect(good.stderr.hasPrefix("Good \"git\" signature for alice@example.com with ED25519 key SHA256:"))
        #expect(good.status == 0)
        let scenarios = [["verify-tag", "v1"], ["verify-tag", "-v", "v1"], ["verify-tag", "--raw", "v1"],
                         ["tag", "-v", "v1"], ["verify-tag", "v2"], ["tag", "-v", "v2"], ["verify-tag", "v1", "v2"]]
        for args in scenarios {
            try await expectParity(args, in: fixture.repo)
        }
        let unknown = try await git(["verify-tag", "v2"], in: fixture.repo)
        #expect(unknown.stderr.contains("No principal matched."))
        #expect(unknown.status == 1)
    }

    @Test("no allowed signers file configured", .enabled(if: hasSSHKeygen))
    func absentAllowedSigners() async throws {
        let fixture = try makeFixture(allowed: false)
        defer { try? FileManager.default.removeItem(at: fixture.repo.deletingLastPathComponent()) }
        let result = try await git(["verify-tag", "v1"], in: fixture.repo)
        #expect(result.stderr == Self.noAllowedSigners)
        #expect(result.status == 1)
        try await expectParity(["verify-tag", "v1"], in: fixture.repo)
        try await expectParity(["tag", "-v", "v1"], in: fixture.repo)
    }

    @Test("a tampered tag fails", .enabled(if: hasSSHKeygen))
    func tamperedTag() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.deletingLastPathComponent()) }
        let object = try systemGit(["cat-file", "tag", "v1"], in: fixture.repo)
            .replacingOccurrences(of: "release v1", with: "release v9")
        let file = fixture.keys.appendingPathComponent("tampered")
        try (object + "\n").write(to: file, atomically: true, encoding: .utf8)
        let oid = try systemGit(["hash-object", "-t", "tag", "-w", file.path], in: fixture.repo)
        try systemGit(["update-ref", "refs/tags/v3", oid], in: fixture.repo)
        let result = try await git(["verify-tag", "v3"], in: fixture.repo)
        #expect(result.status == 1)
        try await expectParity(["verify-tag", "v3"], in: fixture.repo)
        try await expectParity(["tag", "-v", "v3"], in: fixture.repo)
    }

    @Test("a revoked key fails", .enabled(if: hasSSHKeygen))
    func revokedKey() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.deletingLastPathComponent()) }
        let revoked = fixture.keys.appendingPathComponent("revoked")
        try run("ssh-keygen", ["-q", "-k", "-f", revoked.path, fixture.keys.appendingPathComponent("alice.pub").path],
                in: fixture.keys)
        try systemGit(["config", "gpg.ssh.revocationFile", revoked.path], in: fixture.repo)
        let result = try await git(["verify-tag", "v1"], in: fixture.repo)
        #expect(result.status == 1)
        try await expectParity(["verify-tag", "v1"], in: fixture.repo)
        // A revocation file that isn't there is a warning, and the key still good.
        try systemGit(["config", "gpg.ssh.revocationFile", fixture.keys.appendingPathComponent("none").path],
                      in: fixture.repo)
        try await expectParity(["verify-tag", "v1"], in: fixture.repo)
    }

    @Test("a missing or non-executable ssh-keygen is a launch failure", .enabled(if: hasSSHKeygen))
    func unavailableProgram() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.repo.deletingLastPathComponent()) }
        let plain = fixture.keys.appendingPathComponent("plain")
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        for program in ["/nonexistent/ssh-keygen", "nonexistent-ssh-keygen", plain.path] {
            try systemGit(["config", "gpg.ssh.program", program], in: fixture.repo)
            for args in [["verify-tag", "v1"], ["tag", "-v", "v1"]] {
                let result = try await git(args, in: fixture.repo)
                #expect(result.status == 1)
                #expect(result.stderr.contains(program))
                #expect(!result.stderr.contains("Good"))
                try await expectParity(args, in: fixture.repo)
            }
        }
    }

    @Test("sshTagVerificationUnavailableProgram: no processes at all fails, never skips")
    func sshTagVerificationUnavailableProgram() async throws {
        // No ssh-keygen needed: the launcher refuses before anything runs.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerifySSHDenied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try systemGit(["init", "-q", "-b", "main"], in: root)
        try systemGit(["config", "user.name", "Test"], in: root)
        try systemGit(["config", "user.email", "test@example.com"], in: root)
        try Data("x\n".utf8).write(to: root.appendingPathComponent("a"))
        try systemGit(["add", "."], in: root)
        try systemGit(["commit", "-q", "-m", "init"], in: root)
        let commit = try systemGit(["rev-parse", "HEAD"], in: root)
        let object = "object \(commit)\ntype commit\ntag v1\ntagger Test <test@example.com> 1700000000 +0000\n\n"
            + "release\n-----BEGIN SSH SIGNATURE-----\nabc\n-----END SSH SIGNATURE-----\n"
        let file = root.appendingPathComponent(".tagobject")
        try object.write(to: file, atomically: true, encoding: .utf8)
        let oid = try systemGit(["hash-object", "-t", "tag", "-w", file.path], in: root)
        try FileManager.default.removeItem(at: file)
        try systemGit(["update-ref", "refs/tags/v1", oid], in: root)
        try systemGit(["config", "gpg.ssh.allowedSignersFile", root.appendingPathComponent("allowed").path], in: root)
        for args in [["verify-tag", "v1"], ["tag", "-v", "v1"]] {
            let result = try await git(args, in: root, launcher: SandboxedDenyLauncher(reason: "no processes"))
            #expect(result.stderr.hasPrefix("error: cannot run ssh-keygen: "))
            #expect(result.stderr.contains("no processes"))
            #expect(!result.stderr.contains("Good"))
            #expect(result.status == 1)
        }
        // Without an allowed signers file git stops before any program.
        try systemGit(["config", "--unset", "gpg.ssh.allowedSignersFile"], in: root)
        let bare = try await git(["verify-tag", "v1"], in: root, launcher: SandboxedDenyLauncher())
        #expect(bare.stderr == Self.noAllowedSigners)
        #expect(bare.status == 1)
    }

    @Test("merge and octopus templates carry SSH verification, as git's do", .enabled(if: hasSSHKeygen))
    func mergeTemplates() async throws {
        for heads in [["v1"], ["v1", "v2"]] {
            let fixture = try makeFixture()
            let theirs = fixture.repo.deletingLastPathComponent().appendingPathComponent("theirs")
            defer { try? FileManager.default.removeItem(at: fixture.repo.deletingLastPathComponent()) }
            try FileManager.default.copyItem(at: fixture.repo, to: theirs)
            _ = try await git(["merge"] + heads, in: fixture.repo)
            try systemGit(["merge"] + heads, in: theirs)
            let message = try systemGit(["log", "-1", "--format=%B"], in: fixture.repo)
            #expect(message == (try systemGit(["log", "-1", "--format=%B"], in: theirs)))
            #expect(message.contains("# -----BEGIN SSH SIGNATURE-----"))
            #expect(message.contains("# Good \"git\" signature for alice@example.com"))
        }
    }
}
#endif
