// `git tag -v`, `git verify-tag` and the merge message of a signed tag
// (#141), run in a ShellKit shell with a stand-in `gpg` script so no
// test needs a local gpg.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
@testable import SwiftGit
@testable import GitCommand

@Suite("git tag -v / verify-tag / signed-tag merge")
struct GitCommandVerifyTagTests {

    private let host = IsolatedGitHost()

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    @discardableResult
    private func systemGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
        process.currentDirectoryURL = dir
        host.isolate(process)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "git \(args.joined(separator: " ")): \(message)")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fakeGPG(stderr: String, status: [String], code: Int32 = 0) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FakeGPG-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gpg")
        let lines = status.map { "echo '[GNUPG:] \($0)'" }.joined(separator: "\n")
        try "#!/bin/sh\ncat >/dev/null\necho '\(stderr)' >&2\n\(lines)\nexit \(code)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private static let good = ["NEWSIG", "GOODSIG ABCD1234 Tester <t@e>", "VALIDSIG FPR 2020-01-01 1 0 4 0 1 8 PRIM",
                               "TRUST_ULTIMATE"]

    private func addSignedTag(_ name: String, message: String, in dir: URL) throws {
        let commit = try systemGit(["rev-parse", "HEAD"], in: dir)
        let object = "object \(commit)\ntype commit\ntag \(name)\ntagger Test <test@example.com> 1700000000 +0000\n\n"
            + "\(message)\n-----BEGIN PGP SIGNATURE-----\n\nabc\n-----END PGP SIGNATURE-----\n"
        let file = dir.appendingPathComponent(".tagobject-\(name)")
        try object.write(to: file, atomically: true, encoding: .utf8)
        let oid = try systemGit(["hash-object", "-t", "tag", "-w", file.path], in: dir)
        try FileManager.default.removeItem(at: file)
        try systemGit(["update-ref", "refs/tags/\(name)", oid], in: dir)
    }

    /// `main` one commit ahead of the fork point, with branches `one`
    /// and `two` each a commit ahead and signed tags `v1` and `v2` on
    /// them, a lightweight tag `light` and an unsigned annotated `ann`.
    private func makeRepo(program: URL?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("VerifyCLI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try systemGit(["init", "-q", "-b", "main"], in: dir)
        try systemGit(["config", "user.name", "Test"], in: dir)
        try systemGit(["config", "user.email", "test@example.com"], in: dir)
        func commit(_ file: String) throws {
            try Data("\(file)\n".utf8).write(to: dir.appendingPathComponent(file))
            try systemGit(["add", "."], in: dir)
            try systemGit(["commit", "-q", "-m", file], in: dir)
        }
        try commit("base")
        for (branch, tag) in [("one", "v1"), ("two", "v2")] {
            try systemGit(["checkout", "-q", "-b", branch, "main"], in: dir)
            try commit(branch)
            try addSignedTag(tag, message: "release \(tag)", in: dir)
        }
        try systemGit(["tag", "light"], in: dir)
        try systemGit(["tag", "-a", "-m", "annotated", "ann"], in: dir)
        try systemGit(["checkout", "-q", "main"], in: dir)
        try commit("main")
        if let program { try systemGit(["config", "gpg.program", program.path], in: dir) }
        return dir
    }

    /// SwiftPorts' `git` in `dir`: what it printed and its exit status.
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

    @Test("verify-tag: a good signature prints the program's words on stderr and succeeds")
    func verifyTagGood() async throws {
        let repo = try makeRepo(program: try fakeGPG(stderr: "gpg: Good signature", status: Self.good))
        defer { try? FileManager.default.removeItem(at: repo) }
        let plain = try await git(["verify-tag", "v1"], in: repo)
        #expect((plain.stdout, plain.stderr, plain.status) == ("", "gpg: Good signature\n", 0))
        let verbose = try await git(["verify-tag", "-v", "v1"], in: repo)
        #expect(verbose.stdout.hasPrefix("object ") && verbose.stdout.hasSuffix("release v1\n"))
        let raw = try await git(["verify-tag", "--raw", "v1"], in: repo)
        #expect(raw.stderr.contains("[GNUPG:] GOODSIG ABCD1234 Tester <t@e>\n"))
        #expect(raw.status == 0)
    }

    @Test("tag -v: contents on stdout, diagnostics on stderr; failures exit 1")
    func tagVerify() async throws {
        let repo = try makeRepo(program: try fakeGPG(stderr: "gpg: Good signature", status: Self.good))
        defer { try? FileManager.default.removeItem(at: repo) }
        let good = try await git(["tag", "-v", "v1"], in: repo)
        #expect(good.stdout.hasSuffix("release v1\n") && good.stderr == "gpg: Good signature\n" && good.status == 0)

        let unsigned = try await git(["tag", "-v", "ann"], in: repo)
        #expect(unsigned.stdout.hasSuffix("annotated\n"))
        #expect(unsigned.stderr == "error: no signature found\n" && unsigned.status == 1)

        let light = try await git(["tag", "-v", "light"], in: repo)
        #expect(light.stderr == "error: light: cannot verify a non-tag object of type commit.\n")
        #expect(light.status == 1)

        let missing = try await git(["tag", "-v", "nope"], in: repo)
        #expect(missing.stderr == "error: tag 'nope' not found.\n" && missing.status == 1)

        // Every tag is tried; one failure fails the command.
        let several = try await git(["verify-tag", "ann", "v1"], in: repo)
        #expect(several.stderr == "error: no signature found\ngpg: Good signature\n" && several.status == 1)
    }

    @Test("verify-tag: a bad signature fails with the program's words")
    func verifyTagBad() async throws {
        let repo = try makeRepo(program: try fakeGPG(
            stderr: "gpg: BAD signature", status: ["NEWSIG", "BADSIG ABCD1234 Tester <t@e>"], code: 1))
        defer { try? FileManager.default.removeItem(at: repo) }
        let result = try await git(["verify-tag", "v1"], in: repo)
        #expect((result.stdout, result.stderr, result.status) == ("", "gpg: BAD signature\n", 1))
    }

    @Test("verify-tag / tag -v: a program that can't be launched is reported, never skipped")
    func verifyTagUnavailableProgram() async throws {
        let repo = try makeRepo(program: nil)
        defer { try? FileManager.default.removeItem(at: repo) }
        try systemGit(["config", "gpg.program", "/nonexistent/gpg"], in: repo)
        for args in [["verify-tag", "v1"], ["tag", "-v", "v1"]] {
            let result = try await git(args, in: repo)
            #expect(result.stderr == "fatal: cannot exec '/nonexistent/gpg': No such file or directory\n")
            #expect(result.status == 1)
        }
        // No processes at all (a sandbox, iOS): the same kind of failure.
        let gpg = try fakeGPG(stderr: "gpg: Good signature", status: Self.good)
        try systemGit(["config", "gpg.program", gpg.path], in: repo)
        for args in [["verify-tag", "v1"], ["tag", "-v", "v1"]] {
            let result = try await git(args, in: repo, launcher: SandboxedDenyLauncher())
            #expect(result.stderr.hasPrefix("error: cannot run \(gpg.path): "))
            #expect(!result.stderr.contains("Good signature"))
            #expect(result.status == 1)
        }
    }

    @Test("merge of a signed tag: the message carries the signature and verification, commented")
    func mergeSingleSignedTag() async throws {
        let repo = try makeRepo(program: try fakeGPG(stderr: "gpg: Good signature", status: Self.good))
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await git(["merge", "v1"], in: repo)
        let message = try systemGit(["log", "-1", "--format=%B"], in: repo)
        #expect(message == """
            Merge tag 'v1'

            release v1

            # -----BEGIN PGP SIGNATURE-----
            #
            # abc
            # -----END PGP SIGNATURE-----
            # gpg: Good signature
            """)
    }

    @Test("octopus merge of signed tags: each under its own comment, a failed verification said so")
    func mergeOctopusSignedTags() async throws {
        let repo = try makeRepo(program: try fakeGPG(
            stderr: "gpg: BAD signature", status: ["NEWSIG", "BADSIG ABCD1234 Tester <t@e>"], code: 1))
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await git(["merge", "v1", "v2"], in: repo)
        let message = try systemGit(["log", "-1", "--format=%B"], in: repo)
        #expect(message.hasPrefix("Merge tags 'v1' and 'v2'\n\n# tag 'v1'\nrelease v1\n\n# -----BEGIN PGP SIGNATURE-----"))
        #expect(message.contains("# gpg: BAD signature\n\n# tag 'v2'\nrelease v2\n"))
        #expect(message.hasSuffix("# -----END PGP SIGNATURE-----\n# gpg: BAD signature"))
    }
}
#endif
