// `git push` / `git fetch` take git's `[<repository> [<refspec>…]]`, and
// `commit` / `pull` / `clone` take `-q` (#123). Runs the subcommands in a
// ShellKit shell against local bare repositories, with the system `git`
// setting up and inspecting them.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
import SwiftGit
@testable import GitCommand

@Suite("git push / fetch / -q against a local remote")
struct GitCommandRemoteTests {

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private func tmp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    /// The system `git`, for setup and inspection.
    @discardableResult
    private func systemGit(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com"] + args
        process.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure(description: "git \(args.joined(separator: " ")): \(message)")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SwiftPorts' `git`, run in a shell whose working directory is `dir`.
    @discardableResult
    private func git(_ args: [String], in dir: URL) async throws -> (stdout: String, stderr: String) {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(stdout: out, stderr: err,
                          environment: Environment(workingDirectory: dir.path))
        try await shell.withCurrent {
            let parsed = try GitCommand.parseAsRoot(args)
            if var command = parsed as? AsyncParsableCommand {
                try await command.run()
            } else {
                var command = parsed
                try command.run()
            }
        }
        out.finish()
        err.finish()
        return (await out.readAllString(), await err.readAllString())
    }

    /// A bare remote with one commit on `main`, and a clone of it whose
    /// `main` tracks `origin/main`.
    private func makeRemoteAndClone() throws -> (remote: URL, clone: URL) {
        let seed = tmp("GitRemoteSeed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try systemGit(["init", "-q", "-b", "main"], in: seed)
        try Data("one\n".utf8).write(to: seed.appendingPathComponent("file.txt"))
        try systemGit(["add", "."], in: seed)
        try systemGit(["commit", "-q", "-m", "one"], in: seed)

        let remote = tmp("GitRemoteBare")
        try systemGit(["clone", "-q", "--bare", seed.path, remote.path], in: seed)
        let clone = tmp("GitRemoteClone")
        try systemGit(["clone", "-q", remote.path, clone.path], in: seed)
        try systemGit(["config", "user.name", "Test"], in: clone)
        try systemGit(["config", "user.email", "test@example.com"], in: clone)
        return (remote, clone)
    }

    private func commitFile(_ name: String, in repo: URL) throws {
        try Data("\(name)\n".utf8).write(to: repo.appendingPathComponent(name))
        try systemGit(["add", name], in: repo)
        try systemGit(["commit", "-q", "-m", name], in: repo)
    }

    // MARK: push

    @Test("git push with no arguments pushes the branch to its upstream")
    func pushToUpstream() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try commitFile("two.txt", in: clone)
        try await git(["push", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: remote)
                == systemGit(["rev-parse", "HEAD"], in: clone))
    }

    @Test("git push <repository> <refspec>…")
    func pushRepositoryAndRefspecs() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try commitFile("two.txt", in: clone)
        try systemGit(["branch", "dev"], in: clone)
        try await git(["push", "origin", "main", "dev"], in: clone)
        let head = try systemGit(["rev-parse", "HEAD"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: remote) == head)
        #expect(try systemGit(["rev-parse", "dev"], in: remote) == head)
    }

    @Test("git push <repository> pushes the current branch to its upstream")
    func pushRepositoryOnly() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try commitFile("two.txt", in: clone)
        try await git(["push", "origin"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: remote)
                == systemGit(["rev-parse", "HEAD"], in: clone))
    }

    @Test("git push -u <repository> <branch> records and reports the upstream")
    func pushSetsUpstream() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["switch", "-q", "-c", "feature"], in: clone)
        try commitFile("feature.txt", in: clone)
        let output = try await git(["push", "-u", "origin", "feature"], in: clone)
        #expect(try systemGit(["rev-parse", "feature"], in: remote)
                == systemGit(["rev-parse", "HEAD"], in: clone))
        #expect(try systemGit(["config", "branch.feature.remote"], in: clone) == "origin")
        #expect(output.stdout == "branch 'feature' set up to track 'origin/feature'.\n")
    }

    @Test("git push [origin] without an upstream refuses, as push.default=simple does")
    func pushWithoutUpstream() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        for args in [["push"], ["push", "origin"], ["push", "-u", "origin"]] {
            do {
                try await git(args, in: clone)
                Issue.record("expected git \(args.joined(separator: " ")) to fail")
            } catch let error as CLIError {
                #expect(error.lines.first == "fatal: The current branch lonely has no upstream branch.")
                #expect(error.lines.contains("    git push --set-upstream origin lonely"))
                #expect(error.exitCode == 128)
            }
        }
        #expect(throws: Failure.self) { try systemGit(["rev-parse", "--verify", "lonely"], in: remote) }
    }

    @Test("git push to another remote pushes the branch under its own name")
    func pushTriangular() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherBare")
        try systemGit(["init", "-q", "--bare", other.path], in: clone)
        try systemGit(["remote", "add", "other", other.path], in: clone)
        try systemGit(["switch", "-q", "-c", "topic"], in: clone)
        try await git(["push", "other"], in: clone)
        #expect(try systemGit(["rev-parse", "topic"], in: other)
                == systemGit(["rev-parse", "HEAD"], in: clone))
    }

    @Test("push.autoSetupRemote and push.default=current")
    func pushConfiguredDefaults() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["switch", "-q", "-c", "auto"], in: clone)
        try systemGit(["config", "push.autoSetupRemote", "true"], in: clone)
        let auto = try await git(["push"], in: clone)
        #expect(auto.stdout == "branch 'auto' set up to track 'origin/auto'.\n")
        #expect(try systemGit(["config", "branch.auto.merge"], in: clone) == "refs/heads/auto")

        try systemGit(["switch", "-q", "-c", "current"], in: clone)
        try systemGit(["config", "--unset", "push.autoSetupRemote"], in: clone)
        try systemGit(["config", "push.default", "current"], in: clone)
        try await git(["push"], in: clone)
        #expect(try systemGit(["rev-parse", "current"], in: remote)
                == systemGit(["rev-parse", "HEAD"], in: clone))
    }

    @Test("git push refuses an upstream of a different name")
    func pushUpstreamNameMismatch() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["switch", "-q", "-c", "feature", "--track", "origin/main"], in: clone)
        do {
            try await git(["push"], in: clone)
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines.first == "fatal: The upstream branch of your current branch does not match")
            #expect(error.lines.contains("    git push origin HEAD:main"))
        }
    }

    @Test("git fetch and push take a URL or path for <repository>")
    func fetchAndPushAPath() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let mirror = tmp("GitRemoteMirror")
        try systemGit(["init", "-q", "--bare", mirror.path], in: clone)
        try commitFile("two.txt", in: clone)
        try await git(["push", mirror.path, "main"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: mirror)
                == systemGit(["rev-parse", "HEAD"], in: clone))

        try await git(["fetch", remote.path, "main"], in: clone)
        #expect(try systemGit(["rev-parse", "FETCH_HEAD"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
        #expect(try systemGit(["remote"], in: clone) == "origin")
    }

    // MARK: fetch

    @Test("git fetch with no arguments, or just the repository")
    func fetchDefaults() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOther")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("two.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        let pushed = try systemGit(["rev-parse", "HEAD"], in: other)

        try await git(["fetch", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "origin/main"], in: clone) == pushed)

        try commitFile("three.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try await git(["fetch", "origin"], in: clone)
        #expect(try systemGit(["rev-parse", "origin/main"], in: clone)
                == systemGit(["rev-parse", "HEAD"], in: other))
    }

    @Test("git fetch applies every configured refspec")
    func fetchEveryConfiguredRefspec() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["config", "--add", "remote.origin.fetch",
                       "+refs/heads/main:refs/remotes/mirror/main"], in: clone)
        try systemGit(["update-ref", "-d", "refs/remotes/origin/main"], in: clone)
        try await git(["fetch"], in: clone)
        let main = try systemGit(["rev-parse", "main"], in: clone)
        #expect(try systemGit(["rev-parse", "refs/remotes/origin/main"], in: clone) == main)
        #expect(try systemGit(["rev-parse", "refs/remotes/mirror/main"], in: clone) == main)
    }

    // MARK: -q

    @Test("git commit -q and git pull -q print nothing on success")
    func quietCommitAndPull() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try Data("two\n".utf8).write(to: clone.appendingPathComponent("two.txt"))
        try systemGit(["add", "two.txt"], in: clone)
        let commit = try await git(["commit", "-q", "-m", "two"], in: clone)
        #expect(commit.stdout.isEmpty)
        #expect(try systemGit(["log", "-1", "--format=%s"], in: clone) == "two")

        let other = tmp("GitRemotePuller")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try systemGit(["push", "-q", "origin", "main"], in: clone)
        let pull = try await git(["pull", "-q"], in: other)
        #expect(pull.stdout.isEmpty)
        #expect(pull.stderr.isEmpty)
        #expect(try systemGit(["rev-parse", "HEAD"], in: other)
                == systemGit(["rev-parse", "HEAD"], in: clone))
    }

    @Test("git clone -q prints nothing; a local clone ends on `done.`")
    func cloneOutput() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let quiet = try await git(["clone", "-q", remote.path, "quiet"], in: clone)
        #expect(quiet.stderr.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: clone.appendingPathComponent("quiet/file.txt").path))

        let loud = try await git(["clone", remote.path, "loud"], in: clone)
        #expect(loud.stderr == "Cloning into 'loud'...\ndone.\n")
    }
}
#endif
