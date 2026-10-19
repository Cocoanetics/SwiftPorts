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
            // As both entry points do, git's shorthands first.
            let parsed = try GitCommand.parseAsRoot(GitCommand.preprocess(args))
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
        // In the remote's ref order, as git reports them: the branch it
        // has first, then the new one.
        #expect(output.stdout == """
            branch 'main' set up to track 'origin/main'.
            branch 'dev' set up to track 'origin/dev'.

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

    // MARK: push --force / --force-with-lease

    /// Another clone moves `main` on; `clone` then rewrites its own.
    private func diverge(remote: URL, clone: URL) throws -> URL {
        let other = tmp("GitRemoteOtherClone")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try commitFile("theirs.txt", in: other)
        try systemGit(["push", "-q", "origin", "main"], in: other)
        try commitFile("mine.txt", in: clone)
        return other
    }

    private func short(_ rev: String, in repo: URL) throws -> String {
        try systemGit(["rev-parse", "--short", rev], in: repo)
    }

    @Test("git push -f and --force force the update, git's way of saying so")
    func pushForce() async throws {
        for flag in ["-f", "--force"] {
            let (remote, clone) = try makeRemoteAndClone()
            let other = try diverge(remote: remote, clone: clone)
            let url = try systemGit(["config", "remote.origin.url"], in: clone)
            let old = try short("main", in: other), new = try short("main", in: clone)
            let output = try await git(["push", flag], in: clone)
            #expect(output.stderr == "To \(url)\n + \(old)...\(new) main -> main (forced update)\n")
            #expect(try systemGit(["rev-parse", "main"], in: remote)
                    == systemGit(["rev-parse", "main"], in: clone))
        }
    }

    @Test("--no-force takes -f back")
    func pushNoForce() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = try diverge(remote: remote, clone: clone)
        await #expect(throws: CLIError.self) {
            try await git(["push", "-f", "--no-force", "origin", "main"], in: clone)
        }
        #expect(try systemGit(["rev-parse", "main"], in: remote)
                == systemGit(["rev-parse", "main"], in: other))
    }

    @Test("git push -f forces every refspec remote.<name>.push configures, global ones first")
    func pushForceConfiguredRefspecs() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = try diverge(remote: remote, clone: clone)
        try systemGit(["push", "-q", "origin", "main:dev"], in: other)
        try systemGit(["config", "--add", "remote.origin.push", "refs/heads/main:refs/heads/main"], in: clone)
        try systemGit(["config", "--add", "remote.origin.push", "refs/heads/main:refs/heads/dev"], in: clone)
        let url = try systemGit(["config", "remote.origin.url"], in: clone)
        let old = try short("main", in: other), new = try short("main", in: clone)
        let output = try await git(["push", "-f"], in: clone)
        // In the remote's ref order, as git lists them.
        #expect(output.stderr == """
            To \(url)
             + \(old)...\(new) main -> dev (forced update)
             + \(old)...\(new) main -> main (forced update)

            """)
        #expect(try systemGit(["rev-parse", "dev"], in: remote)
                == systemGit(["rev-parse", "main"], in: clone))
    }

    @Test("--force-with-lease forces while the remote is where origin/main says")
    func pushLeaseHolds() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = try diverge(remote: remote, clone: clone)
        try systemGit(["fetch", "-q"], in: clone)
        let url = try systemGit(["config", "remote.origin.url"], in: clone)
        let old = try short("main", in: other), new = try short("main", in: clone)
        let output = try await git(["push", "--force-with-lease"], in: clone)
        #expect(output.stderr == "To \(url)\n + \(old)...\(new) main -> main (forced update)\n")
        #expect(try systemGit(["rev-parse", "main"], in: remote)
                == systemGit(["rev-parse", "main"], in: clone))
    }

    @Test("a stale lease is refused as git refuses it, with no hint")
    func pushLeaseStale() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = try diverge(remote: remote, clone: clone)
        try enablePushAdvice(in: clone)
        let url = try systemGit(["config", "remote.origin.url"], in: clone)
        let mine = try systemGit(["rev-parse", "HEAD"], in: clone)
        for args in [["push", "--force-with-lease"],
                     ["push", "--force-with-lease=main", "origin", "main"],
                     ["push", "--force-with-lease=main:\(mine)", "origin", "main"],
                     ["push", "--force-with-lease=main:", "origin", "main"]] {
            do {
                let output = try await git(args, in: clone)
                Issue.record("expected \(args) to fail: \(output)")
            } catch let error as CLIError {
                #expect(error.lines == ["error: failed to push some refs to '\(url)'"])
                #expect(error.exitCode == 1)
            }
        }
        // With -q, the summary leads the error, as for any refused push.
        do {
            try await git(["push", "-q", "--force-with-lease"], in: clone)
            Issue.record("expected git push -q --force-with-lease to fail")
        } catch let error as CLIError {
            #expect(error.lines == [
                "To \(url)",
                " ! [rejected]        main -> main (stale info)",
                "error: failed to push some refs to '\(url)'"
            ])
        }
        #expect(try systemGit(["rev-parse", "main"], in: remote)
                == systemGit(["rev-parse", "main"], in: other))
    }

    @Test("--force overrides a lease; --no-force-with-lease drops the ones before it")
    func pushLeaseOverrides() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        _ = try diverge(remote: remote, clone: clone)
        await #expect(throws: CLIError.self) {
            try await git(["push", "--force-with-lease", "--no-force-with-lease", "origin", "main"], in: clone)
        }
        try await git(["push", "-q", "-f", "--force-with-lease", "origin", "main"], in: clone)
        #expect(try systemGit(["rev-parse", "main"], in: remote)
                == systemGit(["rev-parse", "main"], in: clone))
    }

    @Test("a lease on another ref leaves this one unforced; a bad <expect> is a usage error")
    func pushLeaseOtherRefAndBadExpect() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = try diverge(remote: remote, clone: clone)
        try systemGit(["fetch", "-q"], in: clone)
        await #expect(throws: CLIError.self) {
            try await git(["push", "--force-with-lease=dev", "origin", "main"], in: clone)
        }
        do {
            try await git(["push", "--force-with-lease=main:nosuch", "origin", "main"], in: clone)
            Issue.record("expected a bad <expect> to fail")
        } catch let error as CLIError {
            #expect(error.lines == ["error: cannot parse expected object name 'nosuch'"])
            #expect(error.exitCode == 129)
        }
        #expect(try systemGit(["rev-parse", "main"], in: remote)
                == systemGit(["rev-parse", "main"], in: other))
    }

    @Test("a push refspec written without a value is refused as git refuses it")
    func pushValuelessRefspec() async throws {
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["config", "--add", "remote.origin.push", "refs/heads/main:refs/heads/main"], in: clone)
        let config = clone.appendingPathComponent(".git/config")
        let original = try String(contentsOf: config, encoding: .utf8)
        // As `[remote "origin"]`, with a tab, and in the older
        // `[remote.origin]`.
        for (header, args) in [("[remote \"origin\"]", ["push", "-f"]), ("[remote \"origin\"]", ["push"]),
                               ("[remote.origin]", ["push", "-f"]), ("[remote\t\"origin\"]", ["push", "-f"])] {
            let text = original + "\(header)\n\tpush\n"
            try text.write(to: config, atomically: true, encoding: .utf8)
            let line = text.split(separator: "\n", omittingEmptySubsequences: false).count - 1
            do {
                try await git(args, in: clone)
                Issue.record("expected \(args) to fail")
            } catch let error as CLIError {
                #expect(error.lines == [
                    "error: missing value for 'remote.origin.push'",
                    "fatal: bad config variable 'remote.origin.push' in file '.git/config' at line \(line)"
                ])
                #expect(error.exitCode == 128)
            }
        }
        // Remotes whose names are escaped in their header, or hold a `]`.
        for (name, header) in [("orig\"in", "[remote \"orig\\\"in\"]"), ("orig]in", "[remote \"orig]in\"]")] {
            try original.write(to: config, atomically: true, encoding: .utf8)
            try systemGit(["remote", "add", name, "../elsewhere"], in: clone)
            let text = try String(contentsOf: config, encoding: .utf8) + "\(header)\n\tpush\n"
            try text.write(to: config, atomically: true, encoding: .utf8)
            let line = text.split(separator: "\n", omittingEmptySubsequences: false).count - 1
            do {
                try await git(["push", "-f", "origin", "main"], in: clone)
                Issue.record("expected the push to fail")
            } catch let error as CLIError {
                #expect(error.lines.last
                        == "fatal: bad config variable 'remote.\(name).push' in file '.git/config' at line \(line)")
            }
        }
    }

    @Test("configGetAll reads a key without a value as empty, as git config --get-all does")
    func configGetAllValueless() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let config = clone.appendingPathComponent(".git/config")
        try (try String(contentsOf: config, encoding: .utf8) + "[foo]\n\tbar\n\tbar = x\n")
            .write(to: config, atomically: true, encoding: .utf8)
        let values = try await Shell(environment: Environment(variables: [:], workingDirectory: clone.path)).withCurrent {
            try await GitClient(workingDirectory: clone).configGetAll("foo.bar")
        }
        // `git config --get-all foo.bar` prints an empty line, then `x`.
        #expect(values == ["", "x"])
    }

    @Test("a bare push key is found in a CRLF config too")
    func pushValuelessRefspecCRLF() async throws {
        let (_, clone) = try makeRemoteAndClone()
        let config = clone.appendingPathComponent(".git/config")
        let text = (try String(contentsOf: config, encoding: .utf8) + "[remote \"origin\"]\n\tpush\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        try text.write(to: config, atomically: true, encoding: .utf8)
        let line = text.components(separatedBy: "\r\n").count - 1
        do {
            try await git(["push", "-f"], in: clone)
            Issue.record("expected the push to fail")
        } catch let error as CLIError {
            #expect(error.lines.last
                    == "fatal: bad config variable 'remote.origin.push' in file '.git/config' at line \(line)")
        }
    }

    @Test("a malformed refspec, typed or configured, is refused as git refuses it")
    func pushInvalidRefspec() async throws {
        for bad in ["", " ", "main:", "refs/heads/*:refs/heads/x", "main:@"] {
            let (_, clone) = try makeRemoteAndClone()
            do {
                try await git(["push", "origin", bad], in: clone)
                Issue.record("expected \(bad) to fail")
            } catch let error as CLIError {
                #expect(error.lines == ["fatal: invalid refspec '\(bad)'"])
                #expect(error.exitCode == 128)
            }
            // Configured, with or without -f, which mustn't change it.
            try systemGit(["config", "--add", "remote.origin.push", bad], in: clone)
            for args in [["push"], ["push", "-f"]] {
                do {
                    try await git(args, in: clone)
                    Issue.record("expected \(args) to fail")
                } catch let error as CLIError {
                    #expect(error.lines == ["fatal: invalid refspec '\(bad)'"])
                }
            }
        }
        // Any remote's malformed push refspec stops every push, typed
        // refspecs or not, as git reads them all with its config.
        let (_, clone) = try makeRemoteAndClone()
        try systemGit(["remote", "add", "other", "../elsewhere"], in: clone)
        try systemGit(["config", "--add", "remote.other.push", " "], in: clone)
        do {
            try await git(["push", "-f", "origin", "main"], in: clone)
            Issue.record("expected the push to fail")
        } catch let error as CLIError {
            #expect(error.lines == ["fatal: invalid refspec ' '"])
        }
        // What git takes stays taken.
        #expect(GitClient.isValidPushRefspec("HEAD~1:refs/heads/older"))
        #expect(GitClient.isValidPushRefspec("+refs/heads/*:refs/heads/copy/*"))
        #expect(GitClient.isValidPushRefspec(":dev"))
        #expect(GitClient.isValidPushRefspec("+:"))
        #expect(GitClient.isValidPushRefspec("v1.0"))
        // A negative refspec is a ref name or pattern alone.
        #expect(GitClient.isValidPushRefspec("^refs/heads/dev"))
        #expect(GitClient.isValidPushRefspec("^refs/heads/d*"))
        for bad in ["^", "+^main", "^main:dest", "^" + String(repeating: "a", count: 40)] {
            #expect(!GitClient.isValidPushRefspec(bad), "\(bad)")
        }
    }

    @Test("a lease value can't pass for the bare or negated forms")
    func pushLeaseValueIsNotAForm() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        let other = try diverge(remote: remote, clone: clone)
        // Unlike the bare flag, this leases a ref named so, which nothing
        // pushed matches: the push is refused as without a lease.
        await #expect(throws: CLIError.self) {
            try await git(["push", "--force-with-lease=\(Push.leaseAll)", "origin", "main"], in: clone)
        }
        #expect(try systemGit(["rev-parse", "main"], in: remote) == systemGit(["rev-parse", "main"], in: other))
    }

    @Test("a full object ID for <expect> is taken as given; all zeros expects the ref absent")
    func pushLeaseFullObjectID() async throws {
        let (remote, clone) = try makeRemoteAndClone()
        _ = try diverge(remote: remote, clone: clone)
        let url = try systemGit(["config", "remote.origin.url"], in: clone)
        // A SHA-256 length is no object ID in this (SHA-1) repository, nor
        // are full-width digits.
        for bad in [String(repeating: "1", count: 64), String(repeating: "\u{FF11}", count: 40)] {
            do {
                try await git(["push", "--force-with-lease=main:\(bad)", "origin", "main"], in: clone)
                Issue.record("expected a usage error")
            } catch let error as CLIError {
                #expect(error.lines == ["error: cannot parse expected object name '\(bad)'"])
                #expect(error.exitCode == 129)
            }
        }
        for expect in [String(repeating: "1", count: 40), String(repeating: "0", count: 40)] {
            do {
                try await git(["push", "-q", "--force-with-lease=main:\(expect)", "origin", "main"], in: clone)
                Issue.record("expected a stale lease")
            } catch let error as CLIError {
                #expect(error.lines.dropFirst().first == " ! [rejected]        main -> main (stale info)")
                #expect(error.lines.last == "error: failed to push some refs to '\(url)'")
            }
        }
        // Absent, a new branch goes through.
        try await git(["push", "-q", "--force-with-lease=newb:\(String(repeating: "0", count: 40))",
                       "origin", "HEAD:newb"], in: clone)
        #expect(try systemGit(["rev-parse", "newb"], in: remote) == systemGit(["rev-parse", "HEAD"], in: clone))
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

    /// `clone` of a remote whose `main` gained tag `v2` and whose `side`
    /// branch (fetched, not on `main`) has tag `vside`.
    private func makeTaggedRemoteAndClone() throws -> (remote: URL, clone: URL, other: URL) {
        let (remote, clone) = try makeRemoteAndClone()
        let other = tmp("GitRemoteTagger")
        try systemGit(["clone", "-q", remote.path, other.path], in: clone)
        try systemGit(["switch", "-q", "-c", "side"], in: other)
        try commitFile("side.txt", in: other)
        try systemGit(["tag", "vside"], in: other)
        try systemGit(["switch", "-q", "main"], in: other)
        try commitFile("two.txt", in: other)
        try systemGit(["tag", "v2"], in: other)
        try systemGit(["push", "-q", "origin", "main", "v2", "vside"], in: other)
        return (remote, clone, other)
    }

    private func tags(_ repo: URL) throws -> [String] {
        try systemGit(["tag", "-l"], in: repo).split(separator: "\n").map(String.init)
    }

    @Test("git fetch --tags and -t fetch every tag; by default only those on what's fetched")
    func fetchTags() async throws {
        for flag in ["--tags", "-t"] {
            let (remote, clone, _) = try makeTaggedRemoteAndClone()
            let output = try await git(["fetch", flag], in: clone)
            #expect(try tags(clone) == ["v2", "vside"])
            #expect(output.stderr.hasSuffix("""
                 * [new tag]         v2         -> v2
                 * [new tag]         vside      -> vside

                """))
            #expect(try systemGit(["rev-parse", "vside"], in: clone)
                    == systemGit(["rev-parse", "vside"], in: remote))
        }
        let (_, clone, _) = try makeTaggedRemoteAndClone()
        try await git(["fetch", "-q"], in: clone)
        let followed = try tags(clone)
        #expect(followed == ["v2"])
    }

    @Test("git fetch --no-tags follows none, over remote.<name>.tagOpt; the last of the two wins")
    func fetchNoTags() async throws {
        let (_, clone, _) = try makeTaggedRemoteAndClone()
        try systemGit(["config", "remote.origin.tagOpt", "--tags"], in: clone)
        try await git(["fetch", "-q", "--tags", "--no-tags"], in: clone)
        #expect(try tags(clone).isEmpty)
        try await git(["fetch", "-q", "--no-tags", "--tags"], in: clone)
        #expect(try tags(clone) == ["v2", "vside"])
        // `-n` is git's short --no-tags.
        try systemGit(["tag", "-d", "v2", "vside"], in: clone)
        try await git(["fetch", "-q", "-t", "-n"], in: clone)
        #expect(try tags(clone).isEmpty)
        try await git(["fetch", "-qtn"], in: clone)
        #expect(try tags(clone).isEmpty)
        try await git(["fetch", "-qnt"], in: clone)
        #expect(try tags(clone) == ["v2", "vside"])
    }

    @Test("remote.<name>.tagOpt --tags fetches every tag, --no-tags none")
    func fetchTagOpt() async throws {
        let (_, clone, _) = try makeTaggedRemoteAndClone()
        try systemGit(["config", "remote.origin.tagOpt", "--no-tags"], in: clone)
        try await git(["fetch", "-q"], in: clone)
        #expect(try tags(clone).isEmpty)
        try systemGit(["config", "remote.origin.tagOpt", "--tags"], in: clone)
        try await git(["fetch", "-q", "origin", "main"], in: clone)
        #expect(try tags(clone) == ["v2", "vside"])
    }

    @Test("git fetch --tags won't clobber a tag that moved on the remote")
    func fetchTagsClobber() async throws {
        let (_, clone, other) = try makeTaggedRemoteAndClone()
        try await git(["fetch", "-q", "--tags"], in: clone)
        let before = try systemGit(["rev-parse", "v2"], in: clone)
        try commitFile("three.txt", in: other)
        try systemGit(["tag", "-f", "v2"], in: other)
        try systemGit(["push", "-q", "-f", "origin", "main", "v2"], in: other)
        do {
            let output = try await git(["fetch", "--tags"], in: clone)
            Issue.record("expected git fetch --tags to fail: \(output)")
        } catch let error as CLIError {
            #expect(error.lines.isEmpty)
            #expect(error.exitCode == 1)
        }
        #expect(try systemGit(["rev-parse", "v2"], in: clone) == before)
        // The rest of the fetch went ahead.
        #expect(try systemGit(["rev-parse", "origin/main"], in: clone)
                == systemGit(["rev-parse", "main"], in: other))
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
