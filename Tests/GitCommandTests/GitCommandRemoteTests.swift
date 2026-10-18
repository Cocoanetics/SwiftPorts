// `git push` / `git fetch` take git's `[<repository> [<refspec>…]]`, and
// `commit` / `pull` / `clone` take `-q` (#123). Runs the subcommands in a
// ShellKit shell against local bare repositories, with the system `git`
// setting up and inspecting them.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
import ShellCommandKit
@testable import SwiftGit
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

    /// Turns git's push hints on in `repo`'s own config, which outranks a
    /// global one: CI's macOS runner image switches them off globally.
    private func enablePushAdvice(in repo: URL) throws {
        for key in PushRejectionAdvice.Switches.keys {
            try systemGit(["config", "advice.\(key)", "true"], in: repo)
        }
    }

    /// SwiftPorts' `git`, run in a shell whose working directory is `dir`.
    @discardableResult
    private func git(
        _ args: [String], in dir: URL, environment variables: [String: String] = [:]
    ) async throws -> (stdout: String, stderr: String) {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(stdout: out, stderr: err,
                          environment: Environment(variables: variables, workingDirectory: dir.path))
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

    @Test("a push git refuses fails with git's verdict and advice")
    func pushRejected() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("theirs.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try commitFile("mine.txt", in: clone)
        try enablePushAdvice(in: clone)
        let url = try systemGit(["config", "remote.origin.url"], in: clone)
        // With -q, git still shows the summary of a failed push.
        do {
            try await git(["push", "-q"], in: clone)
            Issue.record("expected git push -q to fail")
        } catch let error as CLIError {
            #expect(error.lines == [
                "To \(url)",
                " ! [rejected]        main -> main (fetch first)",
                "error: failed to push some refs to '\(url)'",
                "hint: Updates were rejected because the remote contains work that you do not",
                "hint: have locally. This is usually caused by another repository pushing to",
                "hint: the same ref. If you want to integrate the remote changes, use",
                "hint: 'git pull' before pushing again.",
                "hint: See the 'Note about fast-forwards' in 'git push --help' for details."
            ])
            #expect(error.exitCode == 1)
        }

        // Once fetched, the current branch is behind its remote counterpart.
        try systemGit(["fetch", "-q"], in: clone)
        do {
            try await git(["push"], in: clone)
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines.first == "error: failed to push some refs to '\(url)'")
            #expect(error.lines.dropFirst().first
                    == "hint: Updates were rejected because the tip of your current branch is behind")
        }
        #expect(try systemGit(["rev-parse", "main"], in: remote)
                == systemGit(["rev-parse", "main"], in: other))
    }

    @Test("-u to a path records it as typed for the refs a partly refused push sent")
    func pushRejectedSetsTypedUpstream() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let mirror = tmp("GitRemoteMirror")
        try systemGit(["init", "-q", "--bare", "-b", "main", mirror.path], in: clone)
        try systemGit(["push", "-q", mirror.path, "main"], in: clone)
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", mirror.path, other.path], in: clone)
        try commitFile("theirs.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try commitFile("mine.txt", in: clone)
        try systemGit(["branch", "dev"], in: clone)

        let relative = "../\(mirror.lastPathComponent)"
        await #expect(throws: CLIError.self) {
            try await git(["push", "-u", relative, "main", "dev"], in: clone)
        }
        #expect(try systemGit(["rev-parse", "dev"], in: mirror)
                == systemGit(["rev-parse", "dev"], in: clone))
        #expect(try systemGit(["config", "branch.dev.remote"], in: clone) == relative)
        #expect(try systemGit(["config", "branch.main.remote"], in: clone) == "origin")
    }

    @Test("git's advice switches turn a refused push's hints off")
    func pushRejectedAdviceSwitches() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("theirs.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try commitFile("mine.txt", in: clone)
        func hints(_ environment: [String: String] = [:]) async throws -> [String] {
            do {
                try await git(["push"], in: clone, environment: environment)
                Issue.record("expected git push to fail")
            } catch let error as CLIError {
                #expect(error.lines.contains { $0.hasPrefix("error: failed to push some refs to ") })
                return error.lines.filter { $0.hasPrefix("hint: ") }
            }
            return []
        }
        try enablePushAdvice(in: clone)
        #expect(try await hints().count == 5)
        #expect(try await hints(["GIT_ADVICE": "0"]).isEmpty)
        #expect(try await hints(["GIT_ADVICE": "00"]).isEmpty)
        #expect(try await hints(["GIT_ADVICE": ""]).isEmpty)
        #expect(try await hints(["GIT_ADVICE": "YES"]).count == 5)
        #expect(try await hints(["GIT_ADVICE": "-1"]).count == 5)
        // A value that's no boolean is git's error once a hint is due:
        // after the push's own error, in place of the hints.
        do {
            try await git(["push"], in: clone, environment: ["GIT_ADVICE": "bogus"])
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines.count == 2)
            #expect(error.lines.first?.hasPrefix("error: failed to push some refs to ") == true)
            #expect(error.lines.last == "fatal: bad boolean environment value 'bogus' for 'GIT_ADVICE'")
            #expect(error.exitCode == 128)
        }
        // A refusal git gives no hint for never reads it.
        do {
            try await git(["push", "origin", "mian"], in: clone, environment: ["GIT_ADVICE": "bogus"])
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines.first == "error: src refspec mian does not match any")
            #expect(error.exitCode == 1)
        }
        // Nor does a push that goes through.
        try await git(["push", "origin", "main:refs/heads/elsewhere"], in: clone,
                      environment: ["GIT_ADVICE": "bogus"])
        for key in ["pushFetchFirst", "pushUpdateRejected", "pushNonFastForward"] {
            try systemGit(["config", "advice.\(key)", "false"], in: clone)
            #expect(try await hints().isEmpty, "\(key)")
            try systemGit(["config", "advice.\(key)", "true"], in: clone)
        }
        // Another hint's switch leaves this one on; a bad value is git's error.
        try systemGit(["config", "advice.pushNeedsForce", "false"], in: clone)
        #expect(try await hints().count == 5)
        try systemGit(["config", "advice.pushFetchFirst", "bogus"], in: clone)
        do {
            try await git(["push"], in: clone)
            Issue.record("expected git push to fail")
        } catch let error as CLIError {
            #expect(error.lines == ["fatal: bad boolean config value 'bogus' for 'advice.pushfetchfirst'"])
        }
    }

    @Test("a destination git can't complete reads as git's, hint and all")
    func pushUnqualifiedDestination() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let url = try systemGit(["config", "remote.origin.url"], in: clone)
        try commitFile("two.txt", in: clone)
        let expected = [
            "error: The destination you provided is not a full refname (i.e.,",
            "starting with \"refs/\"). We tried to guess what you meant by:",
            "",
            "- Looking for a ref that matches 'x2' on the remote side.",
            "- Checking if the <src> being pushed ('HEAD^')",
            "  is a ref in \"refs/{heads,tags}/\". If so we add a corresponding",
            "  refs/{heads,tags}/ prefix on the remote side.",
            "",
            "Neither worked, so we gave up. You must fully qualify the ref.",
            "hint: The <src> part of the refspec is a commit object.",
            "hint: Did you mean to create a new branch by pushing to",
            "hint: 'HEAD^:refs/heads/x2'?",
            "error: failed to push some refs to '\(url)'"
        ]
        for unqualifiedAdvice in [true, false] {
            if !unqualifiedAdvice {
                try systemGit(["config", "advice.pushUnqualifiedRefName", "false"], in: clone)
            }
            do {
                try await git(["push", "origin", "HEAD^:x2"], in: clone)
                Issue.record("expected git push to fail")
            } catch let error as CLIError {
                #expect(error.lines == expected.filter { unqualifiedAdvice || !$0.hasPrefix("hint: ") })
                #expect(error.exitCode == 1)
            }
        }
    }

    @Test("a push refused before it starts reads as git's")
    func pushRefusedUpFront() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let url = try systemGit(["config", "remote.origin.url"], in: clone)
        try systemGit(["branch", "dev"], in: clone)
        for (refspecs, reason) in [
            (["mian"], "src refspec mian does not match any"),
            (["main:refs/heads/main", "dev:refs/heads/main"],
             "dst ref refs/heads/main receives from more than one src"),
            ([":nope"], "unable to delete 'nope': remote ref does not exist"),
            // Every refusal, as git lists them.
            (["mian", "mian2"], "src refspec mian does not match any\nerror: src refspec mian2 does not match any")
        ] {
            do {
                try await git(["push", "origin"] + refspecs, in: clone)
                Issue.record("expected git push \(refspecs) to fail")
            } catch let error as CLIError {
                #expect(error.lines == "error: \(reason)".components(separatedBy: "\n")
                        + ["error: failed to push some refs to '\(url)'"])
            }
        }
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
        do {
            try await git(["fetch", "a_://host/repo"], in: clone)
            Issue.record("expected git fetch to fail")
        } catch let error as CLIError {
            #expect(error.lines == ["fatal: protocol 'a_' is not supported"])
            #expect(error.exitCode == 128)
        }
    }

    @Test("in a host shell, git's errors keep its words and exit status")
    func errorsThroughTheShellBridge() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(stdout: out, stderr: err,
                          environment: Environment(workingDirectory: clone.path))
        let status = try await shell.withCurrent {
            try await Shell.parsableCommand(GitCommand.self).run(["git", "fetch", "foo://host/x"])
        }
        err.finish()
        // As git prints it: no `Error: ` from ArgumentParser, and 128.
        #expect(await err.readAllString() == """
            git: 'remote-foo' is not a git command. See 'git --help'.
            fatal: remote helper 'foo' aborted session

            """)
        #expect(status.code == 128)
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

    // MARK: pull

    /// What the system `git` writes to stderr, and its exit status, for
    /// `args` run in `dir`.
    private func systemGitStatus(_ args: [String], in dir: URL) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        _ = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, stderr)
    }

    /// A copy of `repo` for the system `git` to run the same command in.
    private func twin(of repo: URL) throws -> URL {
        let copy = tmp("GitRemoteTwin")
        try FileManager.default.copyItem(at: repo, to: copy)
        return copy
    }

    /// Whether the system `git` is 2.54 or later, whose words the
    /// expected refusals are; older ones word some of them differently.
    private func systemGitSpeaksLike254() throws -> Bool {
        let version = try systemGit(["--version"], in: FileManager.default.temporaryDirectory)
        let numbers = version.split(separator: " ").dropFirst(2).first?
            .split(separator: ".").prefix(2).compactMap { Int($0) } ?? []
        guard numbers.count == 2 else { return false }
        return numbers[0] > 2 || (numbers[0] == 2 && numbers[1] >= 54)
    }

    /// Expects SwiftPorts' `git` to refuse `args` in `repo` with git
    /// 2.54's `stderr` and exit `status` — and, with such a system `git`,
    /// that it refuses the same in a copy of `repo`.
    private func expectRefusal(
        _ args: [String], in repo: URL, stderr expected: String, status: Int32,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        if try systemGitSpeaksLike254() {
            let theirs = try systemGitStatus(args, in: try twin(of: repo))
            #expect(theirs.stderr == expected, "system git \(args)", sourceLocation: sourceLocation)
            #expect(theirs.status == status, "system git \(args)", sourceLocation: sourceLocation)
        }
        do {
            try await git(args, in: repo)
            Issue.record("expected git \(args.joined(separator: " ")) to fail", sourceLocation: sourceLocation)
        } catch let error as CLIError {
            #expect(error.lines.map { $0 + "\n" }.joined() == expected, sourceLocation: sourceLocation)
            #expect(error.exitCode == status, sourceLocation: sourceLocation)
        }
    }

    private func noTrackingInformation(_ branch: String, remote: String = "origin", rebasing: Bool = false) -> String {
        """
        There is no tracking information for the current branch.
        Please specify which branch you want to \(rebasing ? "rebase against" : "merge with").
        See git-pull(1) for details.

            git pull <remote> <branch>

        If you wish to set tracking information for this branch you can do so with:

            git branch --set-upstream-to=\(remote)/<branch> \(branch)


        """
    }

    private func notTheBranchRemote(_ remote: String) -> String {
        """
        You asked to pull from the remote '\(remote)', but did not specify
        a branch. Because this is not the default configured remote
        for your current branch, you must specify a branch on the command line.

        """
    }

    private let notOnABranch = """
        You are not currently on a branch.
        Please specify which branch you want to merge with.
        See git-pull(1) for details.

            git pull <remote> <branch>


        """

    private let howToReconcile = """
        hint: You have divergent branches and need to specify how to reconcile them.
        hint: You can do so by running one of the following commands sometime before
        hint: your next pull:
        hint:
        hint:   git config pull.rebase false  # merge
        hint:   git config pull.rebase true   # rebase
        hint:   git config pull.ff only       # fast-forward only
        hint:
        hint: You can replace "git config" with "git config --global" to set a default
        hint: preference for all repositories. You can also pass --rebase, --no-rebase,
        hint: or --ff-only on the command line to override the configured default per
        hint: invocation.
        fatal: Need to specify how to reconcile divergent branches.

        """

    /// With `advice.diverging` configured, which drops the line on how to
    /// turn the hint off.
    private let cannotFastForward = """
        hint: Diverging branches can't be fast-forwarded, you need to either:
        hint:
        hint: \tgit merge --no-ff
        hint:
        hint: or:
        hint:
        hint: \tgit rebase
        fatal: Not possible to fast-forward, aborting.

        """

    /// The clone's `main` and the remote's `main` each with a commit the
    /// other lacks.
    private func makeDiverged() throws -> (remote: URL, clone: URL) {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("theirs.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try commitFile("mine.txt", in: clone)
        try systemGit(["fetch", "-q"], in: clone)
        // CI's macOS runner switches hints off globally.
        try systemGit(["config", "advice.diverging", "true"], in: clone)
        return (remote, clone)
    }

    @Test("git pull merges the upstream branch, whatever its name")
    func pullUpstreamOfAnotherName() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["push", "-q", "origin", "main:feature"], in: clone)
        try systemGit(["fetch", "-q"], in: clone)
        try systemGit(["switch", "-q", "-c", "local", "--track", "origin/feature"], in: clone)
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", "-b", "feature", remote.path, other.path], in: clone)
        try commitFile("feature.txt", in: other)
        try systemGit(["push", "-q", "origin", "feature"], in: other)

        try await git(["pull", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone)
                == systemGit(["rev-parse", "feature"], in: remote))
    }

    @Test("git pull fetches from the branch's own remote")
    func pullUpstreamOnAnotherRemote() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let second = URL(fileURLWithPath: tmp("GitRemoteSecond").path + ".git")
        try systemGit(["init", "-q", "--bare", second.path], in: clone)
        try systemGit(["remote", "add", "second", second.path], in: clone)
        try systemGit(["push", "-q", "-u", "second", "main:topic"], in: clone)
        try systemGit(["switch", "-q", "-c", "work", "--track", "second/topic"], in: clone)
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", "-b", "topic", second.path, other.path], in: clone)
        try commitFile("topic.txt", in: other)
        try systemGit(["push", "-q", "origin", "topic"], in: other)

        try await git(["pull", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone)
                == systemGit(["rev-parse", "topic"], in: second))
    }

    @Test("git pull without an upstream refuses, in git's words")
    func pullWithoutUpstream() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        try await expectRefusal(["pull", "-q"], in: clone,
                                stderr: noTrackingInformation("lonely"), status: 1)
        try await expectRefusal(["pull", "-q", "--rebase"], in: clone,
                                stderr: noTrackingInformation("lonely", rebasing: true), status: 1)
        // An upstream branch without its remote is no upstream.
        try systemGit(["config", "branch.lonely.merge", "refs/heads/main"], in: clone)
        try await expectRefusal(["pull", "-q"], in: clone,
                                stderr: noTrackingInformation("lonely"), status: 1)
        try systemGit(["switch", "-q", "--detach", "main"], in: clone)
        try await expectRefusal(["pull", "-q"], in: clone, stderr: notOnABranch, status: 1)
    }

    @Test("git pull <remote> refuses a remote that isn't the branch's")
    func pullOtherRemoteWithoutBranch() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["remote", "add", "mirror", remote.path], in: clone)
        try await expectRefusal(["pull", "-q", "mirror"], in: clone,
                                stderr: notTheBranchRemote("mirror"), status: 1)
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        try await expectRefusal(["pull", "-q", "origin"], in: clone,
                                stderr: notTheBranchRemote("origin"), status: 1)
        // An empty repository fetches nothing.
        try await expectRefusal(["pull", "-q", ""], in: clone, stderr: notTheBranchRemote(""), status: 1)
        // The upstream's remote, named, merges the upstream.
        try systemGit(["switch", "-q", "main"], in: clone)
        try await git(["pull", "-q", "origin"], in: clone)
    }

    @Test("git pull with an upstream the remote lacks refuses, in git's words")
    func pullUpstreamNotFetched() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["config", "branch.main.merge", "refs/heads/gone"], in: clone)
        try await expectRefusal(["pull", "-q"], in: clone, stderr: """
            Your configuration specifies to merge with the ref 'refs/heads/gone'
            from the remote, but no such ref was fetched.

            """, status: 1)
    }

    @Test("git pull <remote> <branch> merges it with git's message")
    func pullRemoteAndBranch() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let second = URL(fileURLWithPath: tmp("GitRemoteSecond").path + ".git")
        try systemGit(["init", "-q", "--bare", second.path], in: clone)
        try systemGit(["remote", "add", "second", second.path], in: clone)
        try systemGit(["push", "-q", "second", "main:topic"], in: clone)
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", "-b", "topic", second.path, other.path], in: clone)
        try commitFile("topic.txt", in: other)
        try systemGit(["push", "-q", "origin", "topic"], in: other)
        try commitFile("mine.txt", in: clone)
        try systemGit(["switch", "-q", "-c", "work"], in: clone)

        let theirs = try twin(of: clone)
        try systemGit(["pull", "-q", "--no-rebase", "--no-edit", "second", "topic"], in: theirs)
        try await git(["pull", "-q", "--no-rebase", "second", "topic"], in: clone)
        let message = try systemGit(["log", "-1", "--format=%B"], in: clone)
        let expected = try systemGit(["log", "-1", "--format=%B"], in: theirs)
        #expect(message == expected)
        #expect(message.hasPrefix("Merge branch 'topic' of "))
        #expect(message.hasSuffix(" into work"))
        #expect(try systemGit(["rev-parse", "HEAD^2"], in: clone)
                == systemGit(["rev-parse", "topic"], in: second))
    }

    @Test("git pull names a repository typed as a path as git does")
    func pullPathMergeMessage() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["switch", "-q", "-c", "side"], in: clone)
        try commitFile("side.txt", in: clone)
        try systemGit(["switch", "-q", "-c", "work", "main"], in: clone)
        try commitFile("work.txt", in: clone)
        try systemGit(["config", "pull.rebase", "false"], in: clone)

        // From `.`, a local branch, named without a source.
        let theirs = try twin(of: clone)
        try systemGit(["pull", "-q", "--no-edit", ".", "side"], in: theirs)
        try await git(["pull", "-q", ".", "side"], in: clone)
        let local = try systemGit(["log", "-1", "--format=%s"], in: clone)
        #expect(try local == systemGit(["log", "-1", "--format=%s"], in: theirs))
        #expect(local == "Merge branch 'side' into work")

        // A relative path, as typed, without trailing slashes, then
        // without a trailing `.git` (which can leave a slash).
        try systemGit(["reset", "-q", "--hard", "HEAD^"], in: clone)
        try await git(["pull", "-q", "../\(clone.lastPathComponent)/.git/", "side"], in: clone)
        #expect(try systemGit(["log", "-1", "--format=%s"], in: clone)
                == "Merge branch 'side' of ../\(clone.lastPathComponent)/ into work")
        try systemGit(["reset", "-q", "--hard", "HEAD^"], in: clone)
        try await git(["pull", "-q", "../\(clone.lastPathComponent)//", "side"], in: clone)
        #expect(try systemGit(["log", "-1", "--format=%s"], in: clone)
                == "Merge branch 'side' of ../\(clone.lastPathComponent) into work")
    }

    @Test("git pull of branches that diverged follows pull.rebase and pull.ff")
    func pullDivergedFollowsConfig() async throws {
        // Without a say, git refuses; --ff-only and pull.ff=only refuse too.
        let (remote, clone) = try makeDiverged()
        try await expectRefusal(["pull", "-q"], in: clone, stderr: howToReconcile, status: 128)
        try await expectRefusal(["pull", "-q", "--ff-only"], in: clone, stderr: cannotFastForward, status: 128)
        try systemGit(["config", "pull.ff", "only"], in: clone)
        try await expectRefusal(["pull", "-q"], in: clone, stderr: cannotFastForward, status: 128)
        try await expectRefusal(["pull", "-q", "--rebase", "--ff-only"], in: clone,
                                stderr: cannotFastForward, status: 128)

        // --rebase outranks pull.ff=only.
        try await git(["pull", "-q", "--rebase"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD^"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
        #expect(try systemGit(["log", "-1", "--format=%s"], in: clone) == "mine.txt")

        // pull.rebase=true rebases; --no-rebase merges, and --no-ff
        // outranks pull.ff=only.
        for (config, args, merges) in [
            (["pull.rebase", "true"], ["pull", "-q"], false),
            (["pull.rebase", "merges"], ["pull", "-q"], false),
            (["pull.rebase", "true"], ["pull", "-q", "--no-rebase"], true),
            (["pull.ff", "false"], ["pull", "-q"], true),
            (["pull.rebase", "false"], ["pull", "-q"], true),
        ] as [([String], [String], Bool)] {
            let (remote, clone) = try makeDiverged()
            try systemGit(["config"] + config, in: clone)
            try await git(args, in: clone)
            let parents = try systemGit(["log", "-1", "--format=%P"], in: clone).split(separator: " ")
            #expect(parents.count == (merges ? 2 : 1), "\(config) \(args)")
            if !merges {
                #expect(try systemGit(["rev-parse", "HEAD^"], in: clone)
                        == systemGit(["rev-parse", "main"], in: remote))
            }
        }

        let (_, bad) = try makeDiverged()
        try systemGit(["config", "pull.rebase", "bogus"], in: bad)
        try await expectRefusal(["pull", "-q"], in: bad,
                                stderr: "fatal: invalid value for 'pull.rebase': 'bogus'\n", status: 128)
        try systemGit(["config", "--unset", "pull.rebase"], in: bad)
        try systemGit(["config", "pull.ff", "bogus"], in: bad)
        try await expectRefusal(["pull", "-q"], in: bad,
                                stderr: "fatal: invalid value for 'pull.ff': 'bogus'\n", status: 128)
    }

    @Test("git pull that conflicts leaves git's merge message")
    func pullConflictMessage() async throws {
        // Of git's two names for it, the one configured last counts, and
        // `auto` in any case picks a character.
        for comment in [";", "Auto"] {
            let (remote, clone) = try makeRemoteAndClone()
            let other = tmp("GitRemoteOtherClone")
            try systemGit(["clone", "-q", remote.path, other.path], in: clone)
            try Data("theirs\n".utf8).write(to: other.appendingPathComponent("file.txt"))
            try systemGit(["commit", "-q", "-am", "theirs"], in: other)
            try systemGit(["push", "-q", "origin", "main"], in: other)
            try Data("mine\n".utf8).write(to: clone.appendingPathComponent("file.txt"))
            try systemGit(["commit", "-q", "-am", "mine"], in: clone)
            try systemGit(["config", "pull.rebase", "false"], in: clone)
            try systemGit(["config", "core.commentString", "%"], in: clone)
            try systemGit(["config", "core.commentChar", comment], in: clone)

            let theirs = try twin(of: clone)
            _ = try systemGitStatus(["pull", "-q"], in: theirs)
            await #expect(throws: CLIError.self) { try await git(["pull", "-q"], in: clone) }
            let mergeMessage = { (repo: URL) in
                try String(contentsOf: repo.appendingPathComponent(".git/MERGE_MSG"), encoding: .utf8)
            }
            #expect(try mergeMessage(clone) == mergeMessage(theirs), "core.commentChar=\(comment)")
        }
    }

    @Test("MERGE_MSG comments every line, as git writes them")
    func commentedLines() {
        #expect(Pull.commented(["Conflicts:", "\tweird\nname", "\tplain"], with: "#")
                == "# Conflicts:\n#\tweird\n# name\n#\tplain\n")
        #expect(Pull.commented(["a", ""], with: ";") == "; a\n;\n")
    }

    @Test("git pull fetches the upstream by name from a remote that doesn't map it")
    func pullUpstreamFromUnmappedRemote() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["push", "-q", "origin", "main:feature"], in: clone)
        try systemGit(["fetch", "-q"], in: clone)
        try systemGit(["switch", "-q", "-c", "local", "--track", "origin/feature"], in: clone)
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("main.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try systemGit(["switch", "-q", "-c", "feature", "origin/feature"], in: other)
        try commitFile("feature.txt", in: other)
        try systemGit(["push", "-q", "origin", "feature"], in: other)
        try systemGit(["config", "--unset-all", "remote.origin.fetch"], in: clone)

        try await git(["pull", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone)
                == systemGit(["rev-parse", "feature"], in: remote))
    }

    @Test("git pull --rebase replays from the fork point, leaving what the upstream dropped")
    func pullRebaseForkPoint() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("dropped.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try systemGit(["fetch", "-q"], in: clone)
        try systemGit(["switch", "-q", "-c", "work", "--track", "origin/main"], in: clone)
        try commitFile("mine.txt", in: clone)
        // The upstream drops its commit and moves on.
        try systemGit(["reset", "-q", "--hard", "HEAD^"], in: other)
        try commitFile("new.txt", in: other)
        try systemGit(["push", "-q", "--force", "origin", "main"], in: other)

        let theirs = try twin(of: clone)
        try systemGit(["pull", "-q", "--rebase"], in: theirs)
        try await git(["pull", "-q", "--rebase"], in: clone)
        let subjects = try systemGit(["log", "--format=%s"], in: clone)
        #expect(try subjects == systemGit(["log", "--format=%s"], in: theirs))
        #expect(subjects == "mine.txt\nnew.txt\none")
    }

    @Test("the fork point follows the remote's own fetch destination")
    func forkPointDestination() {
        #expect(Pull.destination(of: "refs/heads/main", under: ["+refs/heads/*:refs/cache/origin/*"])
                == "refs/cache/origin/main")
        #expect(Pull.destination(of: "refs/heads/main", under: ["refs/heads/main:refs/remotes/o/m"])
                == "refs/remotes/o/m")
        #expect(Pull.destination(of: "refs/heads/dev", under: ["refs/heads/main:refs/remotes/o/m"]) == nil)
        #expect(Pull.destination(of: "refs/heads/dev",
                                 under: ["+refs/heads/*:refs/remotes/o/*", "^refs/heads/dev"]) == nil)
    }

    @Test("pull.rebase=merges refuses to flatten local merges")
    func pullRebaseMergesRefusesMerges() async throws {
        let (_, clone) = try makeDiverged()
        try systemGit(["switch", "-q", "-c", "side", "HEAD^"], in: clone)
        try commitFile("side.txt", in: clone)
        try systemGit(["switch", "-q", "main"], in: clone)
        try systemGit(["merge", "-q", "--no-ff", "--no-edit", "side"], in: clone)
        let before = try systemGit(["rev-parse", "HEAD"], in: clone)
        try systemGit(["config", "pull.rebase", "merges"], in: clone)
        do {
            try await git(["pull", "-q"], in: clone)
            Issue.record("expected git pull to refuse")
        } catch let error as CLIError {
            #expect(error.lines == ["fatal: rebasing merge commits (pull.rebase=merges) is not supported"])
            #expect(error.exitCode == 128)
        }
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone) == before)
    }

    @Test("git pull <remote> without a fetch refspec merges the remote's HEAD")
    func pullUnmappedRemote() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("two.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try systemGit(["remote", "add", "nomap", remote.path], in: clone)
        try systemGit(["config", "--unset-all", "remote.nomap.fetch"], in: clone)
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        try await git(["pull", "-q", "nomap"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
    }

    @Test("git pull into an unborn branch takes its upstream")
    func pullIntoUnbornBranch() async throws {
        let seed = tmp("GitRemoteSeed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        let remote = tmp("GitRemoteBare")
        try systemGit(["init", "-q", "--bare", "-b", "main", remote.path], in: seed)
        let clone = tmp("GitRemoteClone")
        try systemGit(["clone", "-q", remote.path, clone.path], in: seed)
        try systemGit(["init", "-q", "-b", "main"], in: seed)
        try commitFile("one.txt", in: seed)
        try systemGit(["push", "-q", remote.path, "main"], in: seed)
        // An empty clone's branch has an upstream, but no commit yet.
        try systemGit(["config", "branch.main.remote", "origin"], in: clone)
        try systemGit(["config", "branch.main.merge", "refs/heads/main"], in: clone)

        try await git(["pull", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent("one.txt").path))
    }

    @Test("an empty remote.<name>.fetch maps nothing: git pull <remote> merges its HEAD")
    func pullEmptyFetchRefspec() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("two.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try systemGit(["remote", "add", "blank", remote.path], in: clone)
        try systemGit(["config", "remote.blank.fetch", ""], in: clone)
        // Another remote's mapping, its name differing in case only, isn't blank's.
        try systemGit(["remote", "add", "Blank", remote.path], in: clone)
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        try commitFile("mine.txt", in: clone)
        try systemGit(["config", "pull.rebase", "false"], in: clone)
        let theirs = try twin(of: clone)
        try systemGit(["pull", "-q", "--no-edit", "blank"], in: theirs)
        try await git(["pull", "-q", "blank"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD^2"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
        let subject = try systemGit(["log", "-1", "--format=%s"], in: clone)
        #expect(try subject == systemGit(["log", "-1", "--format=%s"], in: theirs))
    }

    @Test("an empty first fetch refspec merges HEAD beside the other mappings")
    func pullEmptyFirstRefspec() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("two.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try systemGit(["config", "--unset-all", "remote.origin.fetch"], in: clone)
        try systemGit(["config", "remote.origin.fetch", ""], in: clone)
        try systemGit(["config", "--add", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], in: clone)
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        try await git(["pull", "-q", "--no-rebase", "origin"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
    }

    @Test("a remote's HEAD pulled from a path is named as typed")
    func pullPathHeadMessage() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("two.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try commitFile("mine.txt", in: clone)
        let typed = "../\(remote.lastPathComponent)"
        try await git(["pull", "-q", "--no-rebase", typed, "HEAD"], in: clone)
        #expect(try systemGit(["log", "-1", "--format=%s"], in: clone) == "Merge \(typed)")
    }

    @Test("a branch whose remote is `.` merges its upstream without a source")
    func pullFromDotRemote() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["switch", "-q", "-c", "side"], in: clone)
        try commitFile("side.txt", in: clone)
        try systemGit(["switch", "-q", "-c", "work", "main"], in: clone)
        try commitFile("work.txt", in: clone)
        try systemGit(["config", "branch.work.remote", "."], in: clone)
        try systemGit(["config", "branch.work.merge", "refs/heads/side"], in: clone)
        try systemGit(["config", "pull.rebase", "false"], in: clone)

        let theirs = try twin(of: clone)
        try systemGit(["pull", "-q", "--no-edit"], in: theirs)
        try await git(["pull", "-q"], in: clone)
        let subject = try systemGit(["log", "-1", "--format=%s"], in: clone)
        #expect(try subject == systemGit(["log", "-1", "--format=%s"], in: theirs))
        #expect(subject == "Merge branch 'side' into work")
    }

    @Test("without an upstream, git pull <remote> merges its first exact fetch refspec")
    func pullFirstExactRefspec() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("two.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try systemGit(["config", "remote.origin.fetch", "refs/heads/main:refs/remotes/origin/main"], in: clone)
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        try await git(["pull", "-q", "origin"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))
    }

    @Test("git pull fetches an upstream the remote's refspecs don't cover")
    func pullUpstreamNotMapped() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        try systemGit(["push", "-q", "origin", "main:feature"], in: clone)
        try systemGit(["fetch", "-q"], in: clone)
        try systemGit(["switch", "-q", "-c", "local", "--track", "origin/feature"], in: clone)
        try systemGit(["config", "remote.origin.fetch", "refs/heads/main:refs/remotes/origin/main"], in: clone)
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", "-b", "feature", remote.path, other.path], in: clone)
        try commitFile("feature.txt", in: other)
        try systemGit(["push", "-q", "origin", "feature"], in: other)

        try await git(["pull", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone)
                == systemGit(["rev-parse", "feature"], in: remote))
    }

    @Test("an annotated tag outside refs/tags is merged with --no-ff; `tag <name>` fast-forwards")
    func pullAnnotatedTagFastForward() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("two.txt", in: other)
        try systemGit(["tag", "-a", "v1", "-m", "Release one"], in: other)
        try systemGit(["tag", "-a", "v'1", "-m", "Quoted"], in: other)
        try systemGit(["push", "-q", "origin", "main", "v1", "v'1"], in: other)
        let tip = try systemGit(["rev-parse", "main"], in: remote)
        try systemGit(["switch", "-q", "-c", "lonely"], in: clone)
        let start = try systemGit(["rev-parse", "HEAD"], in: clone)

        try await git(["pull", "-q", "--no-rebase", "origin", "v1"], in: clone)
        #expect(try systemGit(["log", "-1", "--format=%P"], in: clone) == "\(start) \(tip)")
        #expect(try systemGit(["log", "-1", "--format=%B"], in: clone).hasSuffix("Release one"))

        for args in [["pull", "-q", "--no-rebase", "--ff", "origin", "v1"],
                     ["pull", "-q", "--no-rebase", "origin", "tag", "v1"],
                     ["pull", "-q", "--no-rebase", "origin", "tag", "v'1"]] {
            try systemGit(["reset", "-q", "--hard", start], in: clone)
            try? systemGit(["tag", "-d", "v1"], in: clone)
            try? systemGit(["tag", "-d", "v'1"], in: clone)
            try await git(args, in: clone)
            #expect(try systemGit(["rev-parse", "HEAD"], in: clone) == tip, "\(args)")
        }
        try await expectRefusal(["pull", "-q", "origin", "tag"], in: clone,
                                stderr: "fatal: you need to specify a tag name\n", status: 1)
    }

    @Test("which upstreams fetch refspecs cover")
    func refspecCoverage() {
        #expect(Pull.refspecs(["+refs/heads/*:refs/remotes/origin/*"], fetch: "refs/heads/feature"))
        #expect(!Pull.refspecs(["refs/heads/main:refs/remotes/origin/main"], fetch: "refs/heads/feature"))
        #expect(Pull.refspecs(["main:refs/remotes/origin/main"], fetch: "refs/heads/main"))
        #expect(!Pull.refspecs(["refs/heads/*:refs/remotes/origin/*", "^refs/heads/feature"],
                               fetch: "refs/heads/feature"))
    }

    @Test("git pull of an annotated tag keeps its message in the merge commit")
    func pullAnnotatedTag() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("two.txt", in: other)
        try systemGit(["tag", "-a", "v1", "-m", "Release one\n\nDetails here."], in: other)
        try systemGit(["push", "-q", "origin", "main", "v1"], in: other)
        try commitFile("mine.txt", in: clone)
        try systemGit(["config", "pull.rebase", "false"], in: clone)

        let theirs = try twin(of: clone)
        try systemGit(["pull", "-q", "--no-edit", "origin", "v1"], in: theirs)
        try await git(["pull", "-q", "origin", "v1"], in: clone)
        let message = try systemGit(["log", "-1", "--format=%B"], in: clone)
        #expect(try message == systemGit(["log", "-1", "--format=%B"], in: theirs))
        #expect(message.hasSuffix("Release one\n\nDetails here."))
    }

    @Test("a valueless pull.rebase is true, an empty one false")
    func pullValuelessBoolean() async throws {
        let (remote, clone) = try makeDiverged()
        let config = clone.appendingPathComponent(".git/config")
        let text = try String(contentsOf: config, encoding: .utf8)
        try (text + "[pull]\n\trebase\n").write(to: config, atomically: true, encoding: .utf8)
        try await git(["pull", "-q"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD^"], in: clone)
                == systemGit(["rev-parse", "main"], in: remote))

        let (_, empty) = try makeDiverged()
        try systemGit(["config", "pull.rebase", ""], in: empty)
        try await git(["pull", "-q"], in: empty)
        #expect(try systemGit(["log", "-1", "--format=%P"], in: empty).split(separator: " ").count == 2)
    }

    // MARK: octopus merges

    /// The clone of a remote whose `a` and `b` change the first and last
    /// line of `f`, `x` its first line as `a` does, but differently, and
    /// whose `main` the clone has gone past with a commit of its own.
    private func makeOctopusRemoteAndClone() throws -> URL {
        let (_, clone) = try makeRemoteAndClone()
        // No background gc or maintenance racing the copies of the clone.
        try systemGit(["config", "gc.auto", "0"], in: clone)
        try systemGit(["config", "maintenance.auto", "false"], in: clone)
        try Data("1\n2\n3\n4\n5\n6\n7\n".utf8).write(to: clone.appendingPathComponent("f"))
        try systemGit(["add", "f"], in: clone)
        try systemGit(["commit", "-q", "-m", "f"], in: clone)
        try systemGit(["push", "-q", "origin", "main"], in: clone)
        for (branch, text) in [("a", "1a\n2\n3\n4\n5\n6\n7\n"), ("b", "1\n2\n3\n4\n5\n6\n7b\n"),
                               ("x", "1x\n2\n3\n4\n5\n6\n7\n")] {
            try systemGit(["switch", "-q", "-c", branch, "main"], in: clone)
            try Data(text.utf8).write(to: clone.appendingPathComponent("f"))
            try systemGit(["commit", "-q", "-am", branch], in: clone)
            try systemGit(["push", "-q", "origin", branch], in: clone)
        }
        try systemGit(["switch", "-q", "main"], in: clone)
        try commitFile("mine.txt", in: clone)
        return clone
    }

    /// SwiftPorts' `git` as the system `git` sees it: exit status, stdout
    /// and stderr, refusals included.
    private func ours(_ args: [String], in dir: URL) async throws -> (status: Int32, stdout: String, stderr: String) {
        let out = OutputSink(), err = OutputSink()
        let shell = Shell(stdout: out, stderr: err,
                          environment: Environment(variables: [:], workingDirectory: dir.path))
        var status: Int32 = 0
        var diagnostic = ""
        try await shell.withCurrent {
            do {
                let parsed = try GitCommand.parseAsRoot(args)
                if var command = parsed as? AsyncParsableCommand {
                    try await command.run()
                } else {
                    var command = parsed
                    try command.run()
                }
            } catch let error as CLIError {
                status = error.exitCode
                diagnostic = error.diagnostic
            }
        }
        out.finish()
        err.finish()
        return (status, await out.readAllString(), await err.readAllString() + diagnostic)
    }

    /// The system `git`'s exit status, stdout and stderr for `args`.
    private func theirs(_ args: [String], in dir: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, stdout, stderr)
    }

    /// What a merge leaves: HEAD's tree, parents and message, the status,
    /// and the merge state for the commit that concludes it.
    private func mergeState(of repo: URL) throws -> [String] {
        let gitDir = repo.appendingPathComponent(".git")
        return [try systemGit(["log", "-1", "--format=%T %P%n%B"], in: repo),
                try systemGit(["status", "--porcelain"], in: repo)]
            + ["MERGE_HEAD", "MERGE_MSG", "MERGE_MODE"].map {
                (try? String(contentsOf: gitDir.appendingPathComponent($0), encoding: .utf8)) ?? "-"
            }
    }

    /// Expects SwiftPorts' `git` to do in `repo` what the system `git`
    /// does in a copy of it: the same output, exit status and result. An
    /// older system `git` (before 2.54) isn't compared against: it words
    /// some refusals differently and leaves a failed octopus half merged.
    @discardableResult
    private func expectLikeGit(
        _ args: [String], in repo: URL, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        guard try systemGitSpeaksLike254() else { return try await ours(args, in: repo) }
        let copy = try twin(of: repo)
        let expected = try theirs(args, in: copy)
        let actual = try await ours(args, in: repo)
        #expect(actual.status == expected.status, "git \(args)", sourceLocation: sourceLocation)
        #expect(actual.stdout == expected.stdout, "git \(args)", sourceLocation: sourceLocation)
        #expect(actual.stderr == expected.stderr, "git \(args)", sourceLocation: sourceLocation)
        #expect(try mergeState(of: repo) == mergeState(of: copy), "git \(args)", sourceLocation: sourceLocation)
        return actual
    }

    @Test("git pull <remote> <a> <b> makes git's octopus merge")
    func pullOctopus() async throws {
        let clone = try makeOctopusRemoteAndClone()
        let result = try await expectLikeGit(["pull", "--no-rebase", "origin", "a", "b"], in: clone)
        #expect(result.stdout.contains("Merge made by the 'octopus' strategy."))
        #expect(try systemGit(["log", "-1", "--format=%P"], in: clone).split(separator: " ").count == 3)
        #expect(try systemGit(["log", "-1", "--format=%s"], in: clone).hasPrefix("Merge branches 'a' and 'b' of "))
    }

    @Test("git pull of several heads names those git's message names")
    func pullOctopusMessage() async throws {
        let clone = try makeOctopusRemoteAndClone()
        let remote = try systemGit(["remote", "get-url", "origin"], in: clone)
        // `a1` is `a` again; `a2` is a commit past `a`; the remote's HEAD is `b`.
        try systemGit(["push", "-q", "origin", "a:a1"], in: clone)
        try systemGit(["tag", "-a", "old", "-m", "old", "a"], in: clone)
        try systemGit(["push", "-q", "origin", "old"], in: clone)
        try systemGit(["tag", "-d", "old"], in: clone)
        try systemGit(["switch", "-q", "a"], in: clone)
        try commitFile("a2.txt", in: clone)
        try systemGit(["push", "-q", "origin", "a:a2"], in: clone)
        try systemGit(["reset", "-q", "--hard", "HEAD~1"], in: clone)
        try systemGit(["switch", "-q", "main"], in: clone)
        try systemGit(["symbolic-ref", "HEAD", "refs/heads/b"], in: URL(fileURLWithPath: remote))
        let start = try systemGit(["rev-parse", "HEAD"], in: clone)
        let cases: [([String], String)] = [
            // `a` is in `a2`'s history, so only `a2` is named.
            (["a", "a2"], "Merge branch 'a2' of"),
            // So is the commit annotated tag `old` names.
            (["old", "a2"], "Merge branch 'a2' of"),
            // The same commit twice is named twice.
            (["a", "a1", "b"], "Merge branches 'a', 'a1' and 'b' of"),
            // The remote's HEAD leads, as `HEAD`.
            (["a", "HEAD"], "Merge HEAD, branch 'a' of"),
        ]
        for (refs, subject) in cases {
            try systemGit(["reset", "-q", "--hard", start], in: clone)
            try await expectLikeGit(["pull", "-q", "--no-rebase", "origin"] + refs, in: clone)
            #expect(try systemGit(["log", "-1", "--format=%s"], in: clone) == subject + " " + remote, "\(refs)")
        }

        // Annotated tags' messages follow, each under a comment naming it.
        try systemGit(["tag", "-a", "ta", "-m", "tag A", "a"], in: clone)
        try systemGit(["tag", "-a", "tb", "-m", "tag B", "b"], in: clone)
        try systemGit(["push", "-q", "origin", "ta", "tb"], in: clone)
        try systemGit(["reset", "-q", "--hard", start], in: clone)
        try await expectLikeGit(["pull", "-q", "--no-rebase", "origin", "ta", "tb"], in: clone)
        #expect(try systemGit(["log", "-1", "--format=%B"], in: clone) == """
            Merge tags 'ta' and 'tb' of \(remote)

            # tag 'ta' of \(remote)
            tag A

            # tag 'tb' of \(remote)
            tag B
            """)
    }

    @Test("git pull of a tag that reduction drops fast-forwards, as git does")
    func pullOctopusDroppedTagFastForwards() async throws {
        let clone = try makeOctopusRemoteAndClone()
        // `old` tags an ancestor of `a`, and stays out of refs/tags here.
        try systemGit(["tag", "-a", "old", "-m", "old", "origin/main"], in: clone)
        try systemGit(["push", "-q", "origin", "old"], in: clone)
        try systemGit(["tag", "-d", "old"], in: clone)
        try systemGit(["switch", "-q", "-c", "behind", "origin/main"], in: clone)
        try await expectLikeGit(["pull", "-q", "--no-rebase", "origin", "old", "a"], in: clone)
        #expect(try systemGit(["rev-parse", "HEAD"], in: clone) == systemGit(["rev-parse", "origin/a"], in: clone))
    }

    @Test("git pull of several heads refuses as git does: rebasing, --ff-only, an unconfigured pull")
    func pullOctopusRefusals() async throws {
        let clone = try makeOctopusRemoteAndClone()
        for args in [["pull", "--rebase", "origin", "a", "b"], ["pull", "--ff-only", "origin", "a", "b"],
                     ["pull", "origin", "a", "b"]] {
            let result = try await expectLikeGit(args, in: clone)
            #expect(result.status == 128)
        }
    }

    @Test("git pull of several heads stops at the last one's conflicts, or gives up on an earlier one's")
    func pullOctopusConflicts() async throws {
        let clone = try makeOctopusRemoteAndClone()
        let gaveUp = try await expectLikeGit(["pull", "--no-rebase", "origin", "a", "x", "b"], in: clone)
        #expect(gaveUp.status == 2)
        #expect(gaveUp.stderr.hasSuffix("Merge with strategy octopus failed.\n"))
        let stopped = try await expectLikeGit(["pull", "--no-rebase", "origin", "a", "b", "x"], in: clone)
        #expect(stopped.status == 1)
        #expect(try systemGit(["status", "--porcelain"], in: clone) == "UU f")
    }

    @Test("git merge <a> <b> merges both, fast-forwarding to the first when it can")
    func mergeOctopus() async throws {
        let clone = try makeOctopusRemoteAndClone()
        // git-merge-octopus speaks its steps even with -q; only "Merge
        // made by…" and the diffstat go.
        let quiet = try await expectLikeGit(["merge", "-q", "a", "b"], in: clone)
        #expect(quiet.stdout.hasPrefix("Trying simple merge with a\n"))
        #expect(!quiet.stdout.contains("Merge made by"))
        try systemGit(["reset", "-q", "--hard", "HEAD~1"], in: clone)
        try await expectLikeGit(["merge", "a", "b"], in: clone)
        try systemGit(["reset", "-q", "--hard", "HEAD~1"], in: clone)
        try systemGit(["reset", "-q", "--hard", "origin/main"], in: clone)
        let result = try await expectLikeGit(["merge", "origin/a", "b"], in: clone)
        #expect(result.stdout.hasPrefix("Fast-forwarding to: origin/a\n"))
        #expect(try systemGit(["log", "-1", "--format=%s"], in: clone)
                == "Merge branch 'b', remote-tracking branch 'origin/a'")

        // An annotated tag's message follows the title.
        try systemGit(["reset", "-q", "--hard", "origin/main"], in: clone)
        try systemGit(["tag", "-a", "ta", "-m", "tag A", "a"], in: clone)
        try await expectLikeGit(["merge", "ta", "b"], in: clone)
        #expect(try systemGit(["log", "-1", "--format=%B"], in: clone) == "Merge branch 'b', tag 'ta'\n\ntag A")
    }

    @Test("git merge of several heads reduces them, and refuses as git does")
    func mergeOctopusReducesAndRefuses() async throws {
        let clone = try makeOctopusRemoteAndClone()
        // `main~1` is already merged: an ordinary merge of `a` is left.
        try await expectLikeGit(["merge", "-q", "main~1", "a"], in: clone)
        try systemGit(["reset", "-q", "--hard", "HEAD~1"], in: clone)
        try await expectLikeGit(["merge", "--ff-only", "a", "b"], in: clone)
        try await expectLikeGit(["merge", "a", "nope"], in: clone)
        try await expectLikeGit(["merge", "a", "x", "b"], in: clone)
        try Data("dirty\n".utf8).write(to: clone.appendingPathComponent("f"))
        try await expectLikeGit(["merge", "a", "b"], in: clone)
        try systemGit(["checkout", "-q", "--", "f"], in: clone)
        // An untracked file where a head's file goes, and untracked files
        // where it puts a file over a directory.
        try systemGit(["switch", "-q", "-c", "d", "origin/main"], in: clone)
        try Data("d\n".utf8).write(to: clone.appendingPathComponent("d"))
        try systemGit(["add", "d"], in: clone)
        try systemGit(["commit", "-q", "-m", "d"], in: clone)
        try systemGit(["switch", "-q", "main"], in: clone)
        try FileManager.default.createDirectory(at: clone.appendingPathComponent("d"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: clone.appendingPathComponent("d/file"))
        try await expectLikeGit(["merge", "a", "d"], in: clone)
        try systemGit(["clean", "-qfd"], in: clone)

        // A bare repository has no work tree to merge in.
        let remote = URL(fileURLWithPath: try systemGit(["remote", "get-url", "origin"], in: clone))
        let bareTheirs = try theirs(["merge", "a", "b"], in: remote)
        let bareOurs = try await ours(["merge", "a", "b"], in: remote)
        #expect(bareOurs.status == bareTheirs.status)
        #expect(bareOurs.stderr == bareTheirs.stderr)

        // A merge waiting to be concluded stops another, and a pull, with
        // or without the advice (CI's macOS runner turns advice off
        // globally, so the clone says).
        try systemGit(["merge", "-q", "--no-commit", "--no-ff", "a"], in: clone)
        for advice in ["true", "false"] {
            try systemGit(["config", "advice.resolveConflict", advice], in: clone)
            try await expectLikeGit(["merge", "b", "x"], in: clone)
            try await expectLikeGit(["pull", "origin", "b", "x"], in: clone)
        }
    }

    @Test("merge titles group FETCH_HEAD's descriptions as fmt-merge-msg does")
    func mergeTitles() {
        func title(_ descriptions: [String], known: [String] = []) -> String {
            SwiftGit.GitClient.mergeTitle(SwiftGit.GitClient.titleEntries(fetchedFrom: descriptions, knownSources: known)
                .map(SwiftGit.GitClient.normalizingSource))
        }
        // A remote's HEAD leads its source's group, whatever its URL holds.
        #expect(title(["/tmp/r'", "branch 'a' of /tmp/r'"]) == "Merge HEAD, branch 'a' of /tmp/r'")
        #expect(title(["branch 'a' of /tmp/r'", "/tmp/r'"]) == "Merge HEAD, branch 'a' of /tmp/r'")
        #expect(title(["branch 'repo", "branch 'a' of branch 'repo"]) == "Merge HEAD, branch 'a' of branch 'repo")
        #expect(title(["x' of y", "branch 'a' of x' of y"]) == "Merge HEAD, branch 'a' of x' of y")
        #expect(title(["branch 'repo"], known: ["branch 'repo"]) == "Merge branch 'repo")
        #expect(title(["/tmp/r'"]) == "Merge /tmp/r'")
        // This repository's HEAD, and its branches, have no source.
        #expect(title([".", "branch 'la' of .", "branch 'lb' of ."]) == "Merge HEAD, branches 'la' and 'lb'")
        // Any other ref is named as a commit.
        #expect(title(["'refs/x' of u", "branch 'a' of u"]) == "Merge branch 'a', commit 'refs/x' of u")
        let local = SwiftGit.GitClient.mergeTitle(["branch 'a'", "commit '1234567'", "tag 'v1'"].map {
            SwiftGit.GitClient.MergeTitleEntry(name: $0, source: nil)
        })
        #expect(local == "Merge branch 'a', tag 'v1'; commit '1234567'")
    }

    @Test("merge.suppressDest takes git's globs")
    func suppressDestGlobs() {
        for (pattern, branch, matches) in [
            ("main", "main", true), ("ma*", "main", true), ("m?in", "main", true),
            ("[tw]ork", "work", true), ("[a-v]ork", "work", false), ("[!w]ork", "work", false),
            ("[^t]ork", "work", true), ("w[]]rk", "w]rk", true), ("w\\ork", "work", true),
            ("\\*", "x", false), ("[w", "w", false), ("main", "mainline", false),
            ("[[:alpha:]]ork", "work", true), ("[[:digit:]]ork", "work", false),
            ("[[:digit:][:lower:]]ork", "work", true), ("[[:bogus:]]ork", "work", false),
            ("?", "é", false), ("??", "é", true), ("[[:alpha:]]", "é", false),
            ("*", "feature/x", false), ("feature/*", "feature/x", true), ("**", "feature/x", true),
            ("**/x", "x", true), ("**/x", "a/b/x", true), ("f?ature/x", "f/ature/x", false),
            ("feature?x", "feature/x", false), ("a**", "a/b", false), ("***", "feature/x", true),
            ("***/x", "a/x", true),
        ] {
            #expect(SwiftGit.GitClient.glob(pattern, matches: branch) == matches, "\(pattern) \(branch)")
        }
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
