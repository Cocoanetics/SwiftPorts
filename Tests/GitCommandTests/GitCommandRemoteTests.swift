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

        // Any of git's boolean spellings, and git's refusal of a bad one.
        try systemGit(["switch", "-q", "-c", "two"], in: clone)
        try systemGit(["config", "push.autoSetupRemote", "2"], in: clone)
        let two = try await git(["push"], in: clone)
        #expect(two.stdout == "branch 'two' set up to track 'origin/two'.\n")
        try systemGit(["switch", "-q", "-c", "bogus"], in: clone)
        try systemGit(["config", "push.autoSetupRemote", "bogus"], in: clone)
        do {
            try await git(["push"], in: clone)
            Issue.record("expected a bad push.autoSetupRemote to be refused")
        } catch let error as CLIError {
            #expect(error.lines == ["fatal: bad boolean config value 'bogus' for 'push.autosetupremote'"])
            #expect(error.exitCode == 128)
        }

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

    @Test("git push goes to branch.<name>.pushRemote, then remote.pushDefault")
    func pushRemoteSelection() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let fork = tmp("GitRemoteFork")
        try systemGit(["init", "-q", "--bare", fork.path], in: clone)
        try systemGit(["remote", "add", "fork", fork.path], in: clone)
        try systemGit(["config", "remote.pushDefault", "origin"], in: clone)
        try systemGit(["config", "branch.main.pushRemote", "fork"], in: clone)
        try commitFile("two.txt", in: clone)
        try await git(["push", "-q"], in: clone)
        let two = try systemGit(["rev-parse", "HEAD"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: fork) == two)
        #expect(try systemGit(["rev-parse", "main"], in: remote) != two)

        // remote.pushDefault beats the branch's own remote.
        try systemGit(["config", "--unset", "branch.main.pushRemote"], in: clone)
        try systemGit(["config", "remote.pushDefault", "fork"], in: clone)
        try commitFile("three.txt", in: clone)
        try await git(["push", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: fork)
                == systemGit(["rev-parse", "HEAD"], in: clone))
        #expect(try systemGit(["rev-parse", "main"], in: remote) != two)
    }

    @Test("remote.<name>.push decides what a bare git push pushes")
    func pushConfiguredRefspecs() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["config", "remote.origin.push", "refs/heads/main:refs/heads/from-config"],
                      in: clone)
        try systemGit(["config", "push.default", "nothing"], in: clone)
        let output = try await git(["push"], in: clone)
        #expect(try systemGit(["rev-parse", "from-config"], in: remote)
                == systemGit(["rev-parse", "HEAD"], in: clone))
        #expect(output.stderr.hasSuffix(" * [new branch]      main -> from-config\n"))
    }

    @Test("push.default=matching pushes the branches both sides have")
    func pushMatching() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["push", "-q", "origin", "main:dev"], in: clone)
        try systemGit(["branch", "dev", "origin/dev"], in: clone)
        try systemGit(["branch", "local-only"], in: clone)
        try commitFile("two.txt", in: clone)
        try systemGit(["branch", "-f", "dev", "HEAD"], in: clone)
        try systemGit(["config", "push.default", "matching"], in: clone)
        try await git(["push", "-q"], in: clone)
        let head = try systemGit(["rev-parse", "HEAD"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: remote) == head)
        #expect(try systemGit(["rev-parse", "dev"], in: remote) == head)
        #expect(throws: Failure.self) {
            try systemGit(["rev-parse", "--verify", "local-only"], in: remote)
        }
    }

    @Test("push.default=upstream refuses a remote that isn't the upstream")
    func pushUpstreamModeElsewhere() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherBare")
        try systemGit(["init", "-q", "--bare", other.path], in: clone)
        try systemGit(["remote", "add", "other", other.path], in: clone)
        try systemGit(["config", "push.default", "upstream"], in: clone)
        do {
            try await git(["push", "other"], in: clone)
            Issue.record("expected git push other to fail")
        } catch let error as CLIError {
            #expect(error.lines == [
                "fatal: You are pushing to remote 'other', which is not the upstream of",
                "your current branch 'main', without telling me what to push",
                "to update which remote branch."
            ])
            #expect(error.exitCode == 128)
        }
    }

    @Test("push.autoSetupRemote records the upstream with current, and on another remote")
    func pushAutoSetupRemote() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["config", "push.autoSetupRemote", "true"], in: clone)
        try systemGit(["config", "push.default", "current"], in: clone)
        try systemGit(["switch", "-q", "-c", "cur"], in: clone)
        let current = try await git(["push"], in: clone)
        #expect(current.stdout == "branch 'cur' set up to track 'origin/cur'.\n")

        let fork = tmp("GitRemoteFork")
        try systemGit(["init", "-q", "--bare", fork.path], in: clone)
        try systemGit(["remote", "add", "fork", fork.path], in: clone)
        try systemGit(["config", "--unset", "push.default"], in: clone)
        try systemGit(["config", "remote.pushDefault", "fork"], in: clone)
        try systemGit(["switch", "-q", "-c", "tri"], in: clone)
        let triangular = try await git(["push"], in: clone)
        #expect(triangular.stdout == "branch 'tri' set up to track 'fork/tri'.\n")
        #expect(try systemGit(["config", "branch.tri.remote"], in: clone) == "fork")
    }

    @Test("git push -u reports each branch it pushed")
    func pushSetUpstreamReportsPushedBranches() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["branch", "dev"], in: clone)
        try systemGit(["branch", "wip"], in: clone)
        let output = try await git(
            ["push", "-u", "origin", "refs/heads/*:refs/heads/*", "^refs/heads/wip"], in: clone)
        #expect(output.stdout == """
            branch 'dev' set up to track 'origin/dev'.
            branch 'main' set up to track 'origin/main'.

            """)
        #expect(throws: Failure.self) { try systemGit(["config", "branch.wip.remote"], in: clone) }
    }

    @Test("with one remote, not named origin, git push and fetch default to it")
    func soleRemoteIsTheDefault() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["remote", "rename", "origin", "upstream"], in: clone)
        try systemGit(["switch", "-q", "-c", "solo"], in: clone)
        try systemGit(["config", "push.default", "current"], in: clone)
        try await git(["push", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "solo"], in: remote)
                == systemGit(["rev-parse", "HEAD"], in: clone))

        try systemGit(["update-ref", "-d", "refs/remotes/upstream/main"], in: clone)
        try await git(["fetch", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "refs/remotes/upstream/main"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
    }

    @Test("git fetch and push take a URL or path for <repository>")
    func fetchAndPushAPath() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let mirror = tmp("GitRemoteMirror")
        try systemGit(["init", "-q", "--bare", mirror.path], in: clone)
        try commitFile("two.txt", in: clone)
        let pushed = try await git(["push", "-u", mirror.path, "main"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: mirror)
                == systemGit(["rev-parse", "HEAD"], in: clone))
        // git confirms the upstream for a URL or path as well.
        #expect(pushed.stdout == "branch 'main' set up to track '\(mirror.path)/main'.\n")

        try await git(["fetch", remote.path, "main"], in: clone)
        #expect(try systemGit(["rev-parse", "FETCH_HEAD"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
        #expect(try systemGit(["remote"], in: clone) == "origin")
    }

    @Test("a relative path is relative to the top of the work tree; -u records it as typed")
    func pushRelativePath() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let mirror = tmp("GitRemoteMirror")
        try systemGit(["init", "-q", "--bare", "-b", "main", mirror.path], in: clone)
        let sub = clone.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        // A sibling of the work tree, so not of `sub`.
        let relative = "../\(mirror.lastPathComponent)"
        let pushed = try await git(["push", "-u", relative, "main"], in: sub)
        #expect(try systemGit(["rev-parse", "main"], in: mirror)
                == systemGit(["rev-parse", "HEAD"], in: clone))
        #expect(try systemGit(["config", "branch.main.remote"], in: clone) == relative)
        #expect(pushed.stdout == "branch 'main' set up to track '\(relative)/main'.\n")

        // The upstream as recorded still works, from anywhere in the tree.
        try commitFile("two.txt", in: clone)
        try await git(["push", "-q"], in: sub)
        #expect(try systemGit(["rev-parse", "main"], in: mirror)
                == systemGit(["rev-parse", "HEAD"], in: clone))
        try await git(["fetch", "-q"], in: sub)
        #expect(try systemGit(["rev-parse", "FETCH_HEAD"], in: clone)
                == systemGit(["rev-parse", "HEAD"], in: clone))
    }

    @Test("without a configured remote, git push refuses and git fetch does nothing")
    func noConfiguredRemote() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["remote", "remove", "origin"], in: clone)
        // A repository in ./origin is never taken for the missing remote.
        let decoy = clone.appendingPathComponent("origin")
        try systemGit(["clone", "-q", "--bare", remote.path, decoy.path], in: clone)
        try commitFile("two.txt", in: clone)
        for mode in ["current", "matching"] {
            try systemGit(["config", "push.default", mode], in: clone)
            do {
                try await git(["push"], in: clone)
                Issue.record("expected git push to fail with push.default=\(mode)")
            } catch let error as CLIError {
                #expect(error.lines.first == "fatal: No configured push destination.")
                #expect(error.lines.contains("    git push <name>"))
                #expect(error.exitCode == 128)
            }
        }
        #expect(try systemGit(["rev-parse", "main"], in: decoy)
                != systemGit(["rev-parse", "HEAD"], in: clone))

        let fetched = try await git(["fetch"], in: clone)
        #expect(fetched.stdout.isEmpty && fetched.stderr.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: clone.appendingPathComponent(".git/FETCH_HEAD").path))
    }

    @Test("a path pushed to counts as a remote: with no other, simple wants an upstream")
    func pushPathWithoutUpstream() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let mirror = tmp("GitRemoteMirror")
        try systemGit(["init", "-q", "--bare", "-b", "main", mirror.path], in: clone)
        try systemGit(["switch", "-q", "-c", "topic"], in: clone)
        // With origin configured, a push to a path is triangular.
        try await git(["push", "-q", mirror.path], in: clone)
        #expect(try systemGit(["rev-parse", "topic"], in: mirror)
                == systemGit(["rev-parse", "HEAD"], in: clone))

        // As the only remote, the path is the branch's remote too.
        try systemGit(["remote", "remove", "origin"], in: clone)
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        do {
            try await git(["push", mirror.path], in: clone)
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines.first == "fatal: The current branch lonely has no upstream branch.")
            #expect(error.lines.contains("    git push --set-upstream \(mirror.path) lonely"))
        }
    }

    @Test("an empty repository is no remote at all")
    func emptyRepository() async throws {
        let (_, clone) = try makeRemoteAndClone()
        for args in [["push", ""], ["push", "", "main"]] {
            do {
                try await git(args, in: clone)
                Issue.record("expected git push '' to fail")
            } catch let error as CLIError {
                #expect(error.lines == ["fatal: bad repository ''"])
                #expect(error.exitCode == 128)
            }
        }
        let fetched = try await git(["fetch", ""], in: clone)
        #expect(fetched.stdout.isEmpty && fetched.stderr.isEmpty)

        try systemGit(["config", "branch.main.remote", ""], in: clone)
        _ = try await git(["fetch"], in: clone)
        #expect(!FileManager.default.fileExists(
            atPath: clone.appendingPathComponent(".git/FETCH_HEAD").path))
        do {
            try await git(["push"], in: clone)
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines.first == "fatal: No configured push destination.")
        }
    }

    @Test("a boolean key without a value is true, an empty one false")
    func valuelessBooleans() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let config = clone.appendingPathComponent(".git/config")
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: config)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        }
        try append("[push]\n\tautoSetupRemote\n")
        try systemGit(["switch", "-q", "-c", "valueless"], in: clone)
        let pushed = try await git(["push"], in: clone)
        #expect(pushed.stdout == "branch 'valueless' set up to track 'origin/valueless'.\n")

        try systemGit(["config", "--unset", "push.autoSetupRemote"], in: clone)
        try append("[push]\n\tautoSetupRemote =\n")
        try systemGit(["switch", "-q", "-c", "empty"], in: clone)
        do {
            try await git(["push"], in: clone)
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines.first == "fatal: The current branch empty has no upstream branch.")
        }

        // fetch.prune without a value prunes.
        try systemGit(["push", "-q", "origin", "--delete", "valueless"], in: clone)
        try append("[fetch]\n\tprune\n")
        try await git(["fetch", "-q"], in: clone)
        #expect(throws: Failure.self) {
            try systemGit(["rev-parse", "--verify", "-q", "refs/remotes/origin/valueless"], in: clone)
        }
    }

    @Test("git clone tells a local path from a scp-style remote as git does")
    func cloneLocality() {
        #expect(Clone.isLocal("/srv/team@host/repo:copy.git"))
        #expect(Clone.isLocal("../repo.git"))
        #expect(!Clone.isLocal("git@host:repo.git"))
        #expect(!Clone.isLocal("host:srv/repo.git"))
        #expect(!Clone.isLocal("file:///srv/repo.git"))
    }

    @Test("a URL whose scheme no transport handles is refused as git refuses it")
    func unknownScheme() async throws {
        let (_, clone) = try makeRemoteAndClone()
        // Not taken for SSH, as libgit2 would.
        for args in [["fetch", "foo://host/x"], ["push", "foo://host/x", "main"], ["clone", "-q", "foo://host/x"]] {
            do {
                try await git(args, in: clone)
                Issue.record("expected git \(args[0]) to fail")
            } catch let error as CLIError {
                #expect(error.lines == [
                    "git: 'remote-foo' is not a git command. See 'git --help'.",
                    "fatal: remote helper 'foo' aborted session"
                ])
                #expect(error.exitCode == 128)
            }
        }
    }

    @Test("git refuses a bad push.default before anything else")
    func pushSettingsComeFirst() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["config", "push.default", "bogus"], in: clone)
        // Even with refspecs that leave push.default unused.
        for args in [["push"], ["push", "origin", "main"]] {
            do {
                try await git(args, in: clone)
                Issue.record("expected git \(args.joined(separator: " ")) to fail")
            } catch let error as CLIError {
                #expect(error.lines.first == "error: malformed value for push.default: bogus")
                #expect(error.exitCode == 128)
            }
        }
        try systemGit(["config", "--unset", "push.default"], in: clone)
        try systemGit(["config", "push.autoSetupRemote", "bogus"], in: clone)
        do {
            try await git(["push", "origin", "main"], in: clone)
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines == ["fatal: bad boolean config value 'bogus' for 'push.autosetupremote'"])
        }
        try systemGit(["config", "--unset", "push.autoSetupRemote"], in: clone)
        try systemGit(["config", "branch.autoSetupMerge", "bogus"], in: clone)
        do {
            try await git(["push", "origin", "main"], in: clone)
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines == ["fatal: bad boolean config value 'bogus' for 'branch.autosetupmerge'"])
        }
        // Its own words and any boolean are fine.
        for value in ["inherit", "always", "simple", "false"] {
            try systemGit(["config", "branch.autoSetupMerge", value], in: clone)
            try await git(["push", "-q", "origin", "main"], in: clone)
        }
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

    @Test("git clone and git remote take the remote exactly as typed")
    func remotesAsTyped() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        // A literal %20 survives (a URL couldn't tell it from a space).
        try await git(["remote", "add", "spaced", "git@host:repos%20team.git"], in: clone)
        #expect(try systemGit(["config", "remote.spaced.url"], in: clone) == "git@host:repos%20team.git")
        try await git(["remote", "set-url", "spaced", "git@[::1]:r.git"], in: clone)
        #expect(try systemGit(["config", "remote.spaced.url"], in: clone) == "git@[::1]:r.git")

        // A path with a space, cloned into its humanish name.
        let spaced = tmp("Git Remote Spaced").appendingPathComponent("project.git")
        try FileManager.default.createDirectory(
            at: spaced.deletingLastPathComponent(), withIntermediateDirectories: true)
        try systemGit(["clone", "-q", "--bare", remote.path, spaced.path], in: clone)
        try await git(["clone", "-q", spaced.path], in: clone)
        #expect(FileManager.default.fileExists(
            atPath: clone.appendingPathComponent("project/file.txt").path))

        // git's refusal when no name can be guessed, and its spelling of
        // a directory given with a trailing slash.
        do {
            try await git(["clone", "host:.git"], in: clone)
            Issue.record("expected git clone to fail")
        } catch let error as CLIError {
            #expect(error.lines == [
                "fatal: No directory name could be guessed.",
                "Please specify a directory on the command line"
            ])
            #expect(error.exitCode == 128)
        }
        let named = try await git(["clone", spaced.path, "named/"], in: clone)
        #expect(named.stderr.hasPrefix("Cloning into 'named'...\n"))
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

    @Test("git fetch keeps out what a configured negative refspec excludes")
    func fetchNegativeRefspec() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["push", "-q", "origin", "main:dev", "main:private"], in: clone)
        for ref in ["dev", "private"] {
            try systemGit(["update-ref", "-d", "refs/remotes/origin/\(ref)"], in: clone)
        }
        try systemGit(["config", "--add", "remote.origin.fetch", "^refs/heads/private"], in: clone)
        try await git(["fetch", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "refs/remotes/origin/dev"], in: clone)
                == systemGit(["rev-parse", "main"], in: clone))
        #expect(throws: Failure.self) {
            try systemGit(["rev-parse", "--verify", "refs/remotes/origin/private"], in: clone)
        }
    }

    @Test("git fetch <remote> without a fetch refspec fetches only its HEAD")
    func fetchWithoutMapping() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["remote", "add", "nomap", remote.path], in: clone)
        try systemGit(["config", "--unset-all", "remote.nomap.fetch"], in: clone)
        try await git(["fetch", "-q", "nomap"], in: clone)
        #expect(try systemGit(["for-each-ref", "refs/remotes/nomap"], in: clone).isEmpty)
        #expect(try systemGit(["rev-parse", "FETCH_HEAD"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
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
        // A file:// URL takes the regular transport: no `done.` line.
        let url = try await git(["clone", "file://\(remote.path)", "viaurl"], in: clone)
        #expect(url.stderr == "Cloning into 'viaurl'...\n")
    }
}
#endif
