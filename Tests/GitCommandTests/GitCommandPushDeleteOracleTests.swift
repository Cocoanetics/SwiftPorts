// `git push -d` / `--delete` (issue #259): the option may precede or follow
// the repository, and each plain target is a deletion. Disposable local
// bare remotes; stdout, stderr, status and the remote's refs are compared
// with system git on the same paths.
#if os(macOS) || os(Linux)
import ArgumentParser
import Foundation
import ShellKit
import Testing
@testable import GitCommand

@Suite("git push --delete matches system git")
struct GitCommandPushDeleteOracleTests {
    private let host = IsolatedGitHost()

    private struct Output: Equatable {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// A bare `origin` with `main`, `topic`, `other` and tag `v1`, and a
    /// clone of it.
    private struct Fixture {
        let root: URL
        let clone: URL
        let remote: URL

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PushDelete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let seed = root.appendingPathComponent("seed")
        let remote = root.appendingPathComponent("remote.git")
        let clone = root.appendingPathComponent("clone")
        let fixture = Fixture(root: root, clone: clone, remote: remote)
        do {
            try gitOK(["init", "-q", "-b", "main", seed.path], in: root)
            try gitOK(["config", "user.name", "Test"], in: seed)
            try gitOK(["config", "user.email", "test@example.com"], in: seed)
            try Data("one\n".utf8).write(to: seed.appendingPathComponent("file.txt"))
            try gitOK(["add", "."], in: seed)
            try gitOK(["commit", "-q", "-m", "one"], in: seed)
            try gitOK(["clone", "-q", "--bare", seed.path, remote.path], in: root)
            try gitOK(["clone", "-q", remote.path, clone.path], in: root)
            try gitOK(["config", "user.name", "Test"], in: clone)
            try gitOK(["config", "user.email", "test@example.com"], in: clone)
            try gitOK(["branch", "topic"], in: clone)
            try gitOK(["branch", "other"], in: clone)
            try gitOK(["tag", "v1"], in: clone)
            try gitOK(["push", "-q", "origin", "topic", "other", "v1"], in: clone)
        } catch {
            fixture.remove()
            throw error
        }
        return fixture
    }

    /// System git, then the port, each from the same repository state.
    /// The port's run is on the paths the system run just used.
    private func compare(_ arguments: [String], in fixture: Fixture) async throws {
        let cloneBak = fixture.root.appendingPathComponent("clone.bak")
        let remoteBak = fixture.root.appendingPathComponent("remote.git.bak")
        for backup in [cloneBak, remoteBak] where FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.copyItem(at: fixture.clone, to: cloneBak)
        try FileManager.default.copyItem(at: fixture.remote, to: remoteBak)
        let expected = try systemGit(arguments, in: fixture.clone)
        let expectedRefs = try listedRefs(fixture.remote)
        try replace(fixture.clone, with: cloneBak)
        try replace(fixture.remote, with: remoteBak)
        let actual = try await portGit(arguments, in: fixture.clone)
        let actualRefs = try listedRefs(fixture.remote)
        #expect(actual.stdout == expected.stdout, "stdout for \(arguments)")
        #expect(actual.stderr == expected.stderr, "stderr for \(arguments)")
        #expect(actual.status == expected.status, "status for \(arguments)")
        #expect(actualRefs == expectedRefs, "remote refs for \(arguments)")
    }

    private func listedRefs(_ remote: URL) throws -> String {
        let listed = try systemGit(
            ["for-each-ref", "--format=%(refname) %(objectname)"], in: remote)
        guard listed.status == 0 else {
            throw Failure(description: listed.stderr)
        }
        return listed.stdout
    }

    private func hasRef(_ name: String, in remote: URL) throws -> Bool {
        try listedRefs(remote).split(separator: "\n").contains { $0.hasPrefix("\(name) ") }
    }

    @discardableResult
    private func gitOK(_ arguments: [String], in directory: URL) throws -> String {
        let result = try systemGit(arguments, in: directory)
        guard result.status == 0 else {
            throw Failure(description: "git \(arguments.joined(separator: " ")): \(result.stderr)")
        }
        return result.stdout
    }

    private func systemGit(_ arguments: [String], in directory: URL) throws -> Output {
        let process = Process()
        host.isolate(process)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Output(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }

    /// The port's `git`, with a thrown ``CLIError`` printed the way the
    /// executable's entry point prints it.
    private func portGit(_ arguments: [String], in directory: URL) async throws -> Output {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(
            stdout: out, stderr: err,
            environment: host.environment(workingDirectory: directory.path))
        shell.sandbox = host.sandbox
        var failure: CLIError?
        do {
            try await shell.withCurrent {
                let parsed = try GitCommand.parseAsRoot(GitCommand.preprocess(arguments))
                var command = try #require(parsed as? AsyncParsableCommand)
                try await command.run()
            }
        } catch let error as CLIError {
            failure = error
        }
        out.finish()
        err.finish()
        let stderr = await err.readAllString() + (failure?.lines.map { $0 + "\n" }.joined() ?? "")
        return Output(stdout: await out.readAllString(), stderr: stderr, status: failure?.exitCode ?? 0)
    }

    private func replace(_ destination: URL, with backup: URL) throws {
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: backup, to: destination)
    }

    /// `git push --delete origin topic` and `git push origin --delete topic`.
    @Test("git push --delete before and after the repository")
    func deleteFlagBeforeAndAfterRemote() async throws {
        for arguments in [
            ["push", "--delete", "origin", "topic"],
            ["push", "origin", "--delete", "topic"]
        ] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try await compare(arguments, in: fixture)
            #expect(try hasRef("refs/heads/topic", in: fixture.remote) == false)
            #expect(try hasRef("refs/heads/main", in: fixture.remote))
        }
    }

    @Test("git push -d before and after the repository")
    func shortDeleteFlagBeforeAndAfterRemote() async throws {
        for arguments in [
            ["push", "-d", "origin", "topic"],
            ["push", "origin", "-d", "topic"],
            ["push", "origin", "topic", "--delete"]
        ] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try await compare(arguments, in: fixture)
            #expect(try hasRef("refs/heads/topic", in: fixture.remote) == false)
        }
    }

    @Test("git push --delete deletes every named ref")
    func deletesSeveralRefs() async throws {
        for arguments in [
            ["push", "--delete", "origin", "topic", "other"],
            ["push", "origin", "--delete", "other", "topic"]
        ] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try await compare(arguments, in: fixture)
            #expect(try hasRef("refs/heads/topic", in: fixture.remote) == false)
            #expect(try hasRef("refs/heads/other", in: fixture.remote) == false)
            #expect(try hasRef("refs/heads/main", in: fixture.remote))
            #expect(try hasRef("refs/tags/v1", in: fixture.remote))
        }
    }

    @Test("a ref the remote does not have is git's missing-ref error")
    func missingRemoteRef() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let before = try listedRefs(fixture.remote)
        for arguments in [
            ["push", "--delete", "origin", "nope"],
            ["push", "origin", "--delete", "nope"],
            ["push", "--delete", "origin", "topic", "nope"]
        ] {
            try await compare(arguments, in: fixture)
            #expect(try listedRefs(fixture.remote) == before)
        }
    }

    @Test("git push --delete with no refs refuses, and does not push the configured refspec")
    func refusesDeleteWithoutRefs() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try Data("two\n".utf8).write(to: fixture.clone.appendingPathComponent("two.txt"))
        try gitOK(["add", "two.txt"], in: fixture.clone)
        try gitOK(["commit", "-q", "-m", "two"], in: fixture.clone)
        try gitOK(["config", "remote.origin.push", "refs/heads/main"], in: fixture.clone)
        let before = try listedRefs(fixture.remote)
        for arguments in [
            ["push", "--delete"],
            ["push", "--delete", "origin"],
            ["push", "origin", "--delete"],
            ["push", "-d", "origin"]
        ] {
            try await compare(arguments, in: fixture)
        }
        #expect(try listedRefs(fixture.remote) == before)
        try await compare(["push", "--delete", "origin", "topic"], in: fixture)
        let after = try listedRefs(fixture.remote)
        #expect(after != before)
        #expect(!after.contains("refs/heads/topic "))
        let mainBefore = try #require(before.split(separator: "\n").first { $0.hasPrefix("refs/heads/main ") })
        #expect(after.split(separator: "\n").contains(mainBefore))
    }

    @Test("an empty or colon-bearing --delete target is refused")
    func refusesEmptyAndColonTargets() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let before = try listedRefs(fixture.remote)
        for arguments in [
            ["push", "--delete", "origin", ""],
            ["push", "--delete", "origin", ":"],
            ["push", "--delete", "origin", ":topic"],
            ["push", "origin", "--delete", ":topic"],
            ["push", "--delete", "origin", "topic:topic"],
            ["push", "--delete", "", "topic"],
            ["push", "--delete", "", ":topic"],
            ["push", "--delete", "origin", "tag"],
            ["push", "origin", "--delete", "tag"]
        ] {
            try await compare(arguments, in: fixture)
        }
        #expect(try listedRefs(fixture.remote) == before)
    }

    @Test("git push --delete origin tag <name> deletes that tag")
    func deletesTagShorthand() async throws {
        for arguments in [
            ["push", "--delete", "origin", "tag", "v1"],
            ["push", "origin", "--delete", "tag", "v1"],
            ["push", "--delete", "origin", "tag", "v1", "other"]
        ] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try await compare(arguments, in: fixture)
            #expect(try hasRef("refs/tags/v1", in: fixture.remote) == false)
        }
    }

    @Test("a raw deletion refspec, with force or a lease, still matches git")
    func rawDeletionForceAndLeaseStillMatch() async throws {
        for arguments in [
            ["push", "origin", ":topic"],
            ["push", "-f", "origin", ":other"],
            ["push", "--force-with-lease", "origin", ":topic"],
            ["push", "-f", "--delete", "origin", "topic"],
            ["push", "--force-with-lease", "--delete", "origin", "topic"],
            ["push", "-df", "origin", "other"]
        ] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try await compare(arguments, in: fixture)
        }
    }
}
#endif
