// Signing commits and tags (#168): `commit -S`, `tag -s`, `cherry-pick -S`,
// `merge -S`, `rebase -S`, `commit.gpgsign`, and reading the signatures
// back with `verify-commit`, `log --show-signature` and the `%G`
// placeholders — compared with the system `git` as the oracle where
// `ssh-keygen` exists. The signing program always runs through the
// shell's `ProcessLauncher`; a sandboxed shell with a registered stub shows
// that, and that a refused launch writes nothing.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ArgumentParser
import ShellKit
import SwiftPortsCommands
@testable import SwiftGit
@testable import GitCommand

private let hasSSHKeygen = FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")

@Suite("git signing: commit -S, tag -s, verify-commit, log --show-signature")
struct GitCommandSigningTests {

    private let host = IsolatedGitHost()

    /// Fixed dates, so ours and git's objects can be compared by id.
    private static let dates = ["GIT_AUTHOR_DATE": "1700000000 +0000", "GIT_COMMITTER_DATE": "1700000000 +0000"]

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
        process.environment?.merge(Self.dates) { _, new in new }
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

    /// Ours, in a shell over `dir` with the isolated host's config and
    /// `environment` on top, its stdout, its stderr and git's last words,
    /// and the status it exits with.
    private func git(
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
    private func makeRepository(_ name: String, in root: URL, key: String?) throws -> URL {
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

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Signing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An ed25519 key pair `name` in `root`, and an allowed signers file
    /// trusting it for `test@example.com`.
    private func makeKey(_ name: String, in root: URL) throws -> (key: String, allowed: String) {
        let result = try run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", name, "-f", name], in: root)
        guard result.status == 0 else { throw Failure(description: result.err) }
        let publicKey = try String(contentsOf: root.appendingPathComponent(name + ".pub"), encoding: .utf8)
        let allowed = root.appendingPathComponent("allowed-" + name)
        try "test@example.com \(publicKey)".write(to: allowed, atomically: true, encoding: .utf8)
        return (root.appendingPathComponent(name).path, allowed.path)
    }

    private func isSigned(_ rev: String, in repo: URL) throws -> Bool {
        try systemGit(["cat-file", "-p", rev], in: repo).contains("\ngpgsig ")
    }

    // MARK: Parsing

    @Test("-S, --gpg-sign and --no-gpg-sign: the last one wins, keys stay attached")
    func gpgSignOptions() throws {
        let argv = GitCommand.preprocess(["commit", "-m", "x", "-S", "-SKEY", "--gpg-sign", "--gpg-sign=K2",
                                          "--no-gpg-sign"])
        #expect(argv == ["commit", "-m", "x", "--gpg-sign=+", "--gpg-sign=+KEY", "--gpg-sign=+",
                         "--gpg-sign=+K2", "--gpg-sign=-"])
        #expect(GPGSign.mode([]) == .config)
        #expect(GPGSign.mode(["+KEY", "-"]) == .noSign)
        #expect(GPGSign.mode(["-", "+"]) == .sign(keyID: nil))
        #expect(GPGSign.mode(["+", "+KEY"]) == .sign(keyID: "KEY"))
        // Other commands' -S (log's pickaxe) and pathspecs are left alone.
        #expect(GitCommand.preprocess(["log", "-Sfoo"]) == ["log", "-Sfoo"])
        #expect(GitCommand.preprocess(["commit", "--", "-S"]) == ["commit", "--", "-S"])
        // Another option's value stays as typed.
        #expect(GitCommand.preprocess(["commit", "-m", "-S", "-S"]) == ["commit", "-m", "-S", "--gpg-sign=+"])
        #expect(GitCommand.preprocess(["commit", "--author", "-SKEY"]) == ["commit", "--author", "-SKEY"])
        #expect(GitCommand.preprocess(["merge", "--message", "--no-gpg-sign"])
            == ["merge", "--message", "--no-gpg-sign"])
        #expect(GitCommand.preprocess(["pull", "-m", "--gpg-sign"]) == ["pull", "-m", "--gpg-sign"])
        #expect(GitCommand.preprocess(["rebase", "--onto", "-S", "main"]) == ["rebase", "--onto", "-S", "main"])
        for command in ["merge", "cherry-pick", "rebase", "pull"] {
            #expect(GitCommand.preprocess([command, "-S"]) == [command, "--gpg-sign=+"])
        }
    }

    @Test("git's default-key command line is split as split_cmdline splits it")
    func splitCommandLine() {
        #expect(GitClient.splitCommandLine("ssh-add -L") == ["ssh-add", "-L"])
        #expect(GitClient.splitCommandLine(#"sh -c 'echo "a b"'"#) == ["sh", "-c", #"echo "a b""#])
        #expect(GitClient.splitCommandLine(#"a "b\"c" ''"#) == ["a", #"b"c"#, ""])
        #expect(GitClient.literalSSHKey("key::ssh-ed25519 AAAA") == "ssh-ed25519 AAAA")
        #expect(GitClient.literalSSHKey("ssh-ed25519 AAAA") == "ssh-ed25519 AAAA")
        #expect(GitClient.literalSSHKey("~/.ssh/id_ed25519") == nil)
    }

    // MARK: Signing through the shell

    @Test("a registered signing program runs through the shell, never Process")
    func stubSignerThroughShell() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepository("repo", in: root, key: "~/signing-key")
        try systemGit(["config", "gpg.ssh.program", "stub-signer"], in: repo)
        let calls = Calls()
        let stub = ClosureCommand(name: "stub-signer") { argv in
            await calls.append(argv)
            let file = Shell.current.resolve(argv.last ?? "")
            try Data("-----BEGIN SSH SIGNATURE-----\r\nstub\n-----END SSH SIGNATURE-----\n".utf8)
                .write(to: file.appendingPathExtension("sig"))
            return .success
        }
        // Nothing but registered commands can run.
        let launcher = ChainLauncher(primary: RegisteredCommandLauncher(),
                                     fallback: SandboxedDenyLauncher(reason: "no processes"))
        let result = try await git(["commit", "-S", "--allow-empty", "-q", "-m", "signed"], in: repo,
                                   launcher: launcher, commands: [stub])
        #expect(result.stderr == "")
        #expect(result.status == 0)
        let object = try systemGit(["cat-file", "-p", "HEAD"], in: repo)
        #expect(object.contains("gpgsig -----BEGIN SSH SIGNATURE-----\n stub\n -----END SSH SIGNATURE-----\n"))
        let argv = try #require(await calls.all.first)
        // `~` is the shell's HOME, as git's interpolate_path has it.
        #expect(Array(argv.prefix(7)) == ["stub-signer", "-Y", "sign", "-n", "git", "-f",
                                          host.home.path + "/signing-key"])
        #expect(argv.last?.contains(".git_signing_buffer_tmp") == true)
        // The temporary files are gone.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: host.sandbox.temporaryDirectory.path).filter { $0.hasPrefix(".git_signing") }
        #expect(leftovers.isEmpty)

        // `-m -S` is a message, as in git: an unsigned commit named `-S`.
        let message = try await git(["commit", "--allow-empty", "-q", "-m", "-S"], in: repo,
                                    launcher: launcher, commands: [stub])
        #expect(message.status == 0, "\(message.stderr)")
        #expect(try systemGit(["log", "-1", "--format=%s"], in: repo) == "-S")
        #expect(try !isSigned("HEAD", in: repo))
        #expect(await calls.all.count == 1)

        // A literal key goes into a file of its own, with -U.
        try systemGit(["config", "user.signingkey", "key::ssh-ed25519 AAAAliteral"], in: repo)
        _ = try await git(["commit", "-S", "--allow-empty", "-q", "-m", "literal"], in: repo,
                          launcher: launcher, commands: [stub])
        let literal = try #require(await calls.all.last)
        #expect(literal.contains("-U"))
        #expect(literal[6].contains(".git_signing_key_tmp"))
    }

    @Test("a refused launch says so as git does and writes nothing")
    func refusedLaunch() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepository("repo", in: root, key: "/nonexistent/key")
        try systemGit(["config", "gpg.ssh.program", "/bin/sh"], in: repo)
        let head = try systemGit(["rev-parse", "HEAD"], in: repo)
        let commit = try await git(["commit", "-S", "--allow-empty", "-m", "x"], in: repo,
                                   launcher: SandboxedDenyLauncher(reason: "no processes"))
        #expect(commit.stderr == "error: cannot run /bin/sh: Operation not permitted (no processes)\n"
            + "error: \nfatal: failed to write commit object\n")
        #expect(commit.status == 128)
        #expect(try systemGit(["rev-parse", "HEAD"], in: repo) == head)

        let tag = try await git(["tag", "-s", "v1", "-m", "x"], in: repo,
                                launcher: SandboxedDenyLauncher(reason: "no processes"))
        #expect(tag.stderr.hasSuffix("error: \nerror: unable to sign the tag\n"
            + "The tag message has been left in .git/TAG_EDITMSG\n"))
        #expect(tag.status == 128)
        #expect(try run("git", ["rev-parse", "--verify", "-q", "refs/tags/v1"], in: repo).status != 0)

        // No key and no default-key command: git dies before any program.
        try systemGit(["config", "--unset", "user.signingkey"], in: repo)
        let nokey = try await git(["commit", "-S", "--allow-empty", "-m", "x"], in: repo,
                                  launcher: SandboxedDenyLauncher())
        #expect(nokey.stderr == "fatal: either user.signingkey or gpg.ssh.defaultKeyCommand needs to be configured\n")
        #expect(nokey.status == 128)
    }

    @Test("commit.gpgsign, GIT_CONFIG_COUNT, -S and --no-gpg-sign: git's precedence")
    func signingPrecedence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeRepository("repo", in: root, key: "/k")
        try systemGit(["config", "gpg.ssh.program", "stub-signer"], in: repo)
        let stub = ClosureCommand(name: "stub-signer") { argv in
            let file = Shell.current.resolve(argv.last ?? "")
            try Data("-----BEGIN SSH SIGNATURE-----\nstub\n-----END SSH SIGNATURE-----\n".utf8)
                .write(to: file.appendingPathExtension("sig"))
            return .success
        }
        let launcher = ChainLauncher(primary: RegisteredCommandLauncher(), fallback: SandboxedDenyLauncher())
        let command = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "commit.gpgsign"]
        let cases: [PrecedenceCase] = [
            .init(config: nil, environment: [:], flags: [], signed: false),
            .init(config: "true", environment: [:], flags: [], signed: true),
            .init(config: "true", environment: [:], flags: ["--no-gpg-sign"], signed: false),
            .init(config: "false", environment: [:], flags: ["-S"], signed: true),
            .init(config: "false", environment: command.merging(["GIT_CONFIG_VALUE_0": "true"]) { _, new in new },
                  flags: [], signed: true),
            .init(config: "true", environment: command.merging(["GIT_CONFIG_VALUE_0": "false"]) { _, new in new },
                  flags: [], signed: false),
            .init(config: "false", environment: [:], flags: ["-S", "--no-gpg-sign"], signed: false),
            .init(config: "false", environment: [:], flags: ["--no-gpg-sign", "--gpg-sign"], signed: true)
        ]
        for (index, test) in cases.enumerated() {
            if let config = test.config {
                try systemGit(["config", "commit.gpgsign", config], in: repo)
            }
            let result = try await git(["commit", "--allow-empty", "-q", "-m", "c\(index)"] + test.flags, in: repo,
                                       environment: test.environment, launcher: launcher, commands: [stub])
            #expect(result.status == 0, "\(test)")
            #expect(try isSigned("HEAD", in: repo) == test.signed, "\(test)")
        }

        // tag.gpgsign signs (and annotates) a plain `git tag <name>`;
        // --no-sign doesn't; -u always signs.
        try systemGit(["config", "tag.gpgsign", "true"], in: repo)
        for (name, flags, signed) in [("t1", [String](), true), ("t2", ["--no-sign", "-m", "m"], false),
                                      ("t3", ["--no-sign", "-u", "/k2", "-m", "m"], true)] {
            let result = try await git(["tag", name] + flags + (flags.isEmpty ? ["-m", "m"] : []), in: repo,
                                       launcher: launcher, commands: [stub])
            #expect(result.status == 0)
            #expect(try systemGit(["cat-file", "-t", name], in: repo) == "tag")
            #expect(try systemGit(["cat-file", "-p", name], in: repo).contains("SSH SIGNATURE") == signed, "\(name)")
        }
        // tag.forceSignAnnotated signs a tag annotated by -m alone.
        try systemGit(["config", "tag.gpgsign", "false"], in: repo)
        try systemGit(["config", "tag.forceSignAnnotated", "true"], in: repo)
        _ = try await git(["tag", "t4", "-m", "m"], in: repo, launcher: launcher, commands: [stub])
        #expect(try systemGit(["cat-file", "-p", "t4"], in: repo).contains("SSH SIGNATURE"))
        _ = try await git(["tag", "t5"], in: repo, launcher: launcher, commands: [stub])
        #expect(try systemGit(["cat-file", "-t", "t5"], in: repo) == "commit")
    }

    // MARK: Parity with git

    @Test("commit -S, tag -s and cherry-pick -S write git's objects, which git verifies",
          .enabled(if: hasSSHKeygen))
    func signedObjectsMatchGit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (key, allowed) = try makeKey("alice", in: root)
        var ids: [[String]] = []
        for ours in [true, false] {
            let repo = try makeRepository(ours ? "ours" : "theirs", in: root, key: key)
            try systemGit(["checkout", "-q", "-b", "side"], in: repo)
            try Data("b\n".utf8).write(to: repo.appendingPathComponent("b"))
            try systemGit(["add", "."], in: repo)
            try systemGit(["commit", "-q", "-m", "b"], in: repo)
            try systemGit(["checkout", "-q", "main"], in: repo)
            for args in [["commit", "-S", "--allow-empty", "-q", "-m", "signed"],
                         ["tag", "-s", "v1", "-m", "release"],
                         ["cherry-pick", "-S", "side"]] {
                if ours {
                    let result = try await git(args, in: repo)
                    #expect(result.status == 0, "\(args): \(result.stderr)")
                } else {
                    try systemGit(args, in: repo)
                }
            }
            ids.append(try ["HEAD~1", "v1", "HEAD"].map { try systemGit(["rev-parse", $0], in: repo) })
            try systemGit(["config", "gpg.ssh.allowedSignersFile", allowed], in: repo)
            for args in [["verify-commit", "HEAD~1"], ["verify-commit", "HEAD"], ["verify-tag", "v1"]] {
                #expect(try run("git", args, in: repo).status == 0, "\(args)")
            }
        }
        #expect(ids[0] == ids[1])
    }

    @Test("merge -S and rebase -S sign what they write, as git verifies", .enabled(if: hasSSHKeygen))
    func signedMergeAndRebase() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (key, allowed) = try makeKey("alice", in: root)
        let repo = try makeRepository("repo", in: root, key: key)
        try systemGit(["config", "gpg.ssh.allowedSignersFile", allowed], in: repo)
        for (branch, file) in [("side", "b"), ("topic", "t")] {
            try systemGit(["checkout", "-q", "-b", branch, "main"], in: repo)
            try Data("\(file)\n".utf8).write(to: repo.appendingPathComponent(file))
            try systemGit(["add", "."], in: repo)
            try systemGit(["commit", "-q", "-m", file], in: repo)
        }
        try systemGit(["checkout", "-q", "main"], in: repo)
        let merge = try await git(["merge", "-S", "--no-ff", "side", "-m", "merge side"], in: repo)
        #expect(merge.status == 0, "\(merge.stderr)")
        #expect(try run("git", ["verify-commit", "HEAD"], in: repo).status == 0)
        try systemGit(["checkout", "-q", "topic"], in: repo)
        let rebase = try await git(["rebase", "-S", "main"], in: repo)
        #expect(rebase.status == 0, "\(rebase.stderr)")
        #expect(try run("git", ["verify-commit", "HEAD"], in: repo).status == 0)
        #expect(try systemGit(["rev-parse", "HEAD~1"], in: repo) == systemGit(["rev-parse", "main"], in: repo))
    }

    @Test("verify-commit and log --show-signature say what git says: good, unknown key, bad, unsigned",
          .enabled(if: hasSSHKeygen))
    func verificationMatchesGit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (alice, allowed) = try makeKey("alice", in: root)
        let (mallory, _) = try makeKey("mallory", in: root)
        let repo = try makeRepository("repo", in: root, key: alice)
        try systemGit(["config", "gpg.ssh.allowedSignersFile", allowed], in: repo)
        try systemGit(["commit", "-S", "--allow-empty", "-q", "-m", "good"], in: repo)
        try systemGit(["tag", "good"], in: repo)
        try systemGit(["-c", "user.signingkey=\(mallory)", "commit", "-S", "--allow-empty", "-q", "-m", "unknown"],
                      in: repo)
        try systemGit(["tag", "unknown"], in: repo)
        // A signed commit whose message changed under its signature.
        let signed = try systemGit(["cat-file", "commit", "good"], in: repo)
        let file = root.appendingPathComponent("tampered")
        try (signed.replacingOccurrences(of: "\n\ngood", with: "\n\ntampered") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        let tampered = try systemGit(["hash-object", "-t", "commit", "-w", file.path], in: repo)
        try systemGit(["tag", "bad", tampered], in: repo)
        try systemGit(["tag", "unsigned", "HEAD~2"], in: repo)

        let format = "--format=%h %G? [%GS] [%GK] [%GF] [%GP] [%GT] [%GG]"
        var runs: [[String]] = []
        for name in ["good", "unknown", "bad", "unsigned"] {
            runs += [["verify-commit", name], ["verify-commit", "-v", name], ["verify-commit", "--raw", name],
                     ["log", "-1", "--show-signature", name], ["log", "-1", "--show-signature", "--oneline", name],
                     ["log", "-1", format, name], ["show", "--show-signature", name]]
        }
        runs += [["verify-commit", "nonexistent"], ["verify-commit", "HEAD^{tree}"]]
        for args in runs {
            let ours = try await git(args, in: repo)
            let theirs = try run("git", args, in: repo)
            #expect(ours.stdout == theirs.out, "stdout of \(args)")
            #expect(ours.stderr == theirs.err, "stderr of \(args)")
            #expect(ours.status == theirs.status, "status of \(args)")
        }
    }

    @Test("the registered ssh-keygen signs a commit with no process at all", .enabled(if: hasSSHKeygen))
    func registeredKeygenSigns() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (key, allowed) = try makeKey("alice", in: root)
        let repo = try makeRepository("repo", in: root, key: key)
        let launcher = ChainLauncher(primary: RegisteredCommandLauncher(),
                                     fallback: SandboxedDenyLauncher(reason: "no processes"))
        let result = try await git(["commit", "-S", "--allow-empty", "-q", "-m", "in-process"], in: repo,
                                   environment: ["PATH": ""], launcher: launcher,
                                   commands: SwiftPortsCommands.argumentParserCommands)
        #expect(result.stderr == "")
        #expect(result.status == 0)
        try systemGit(["config", "gpg.ssh.allowedSignersFile", allowed], in: repo)
        #expect(try run("git", ["verify-commit", "HEAD"], in: repo).status == 0)
    }
}

/// One commit of the precedence test: `commit.gpgsign` in the repository
/// (`nil`: left as it is), the shell's extra environment, the flags, and
/// whether git signs.
private struct PrecedenceCase {
    var config: String?
    var environment: [String: String]
    var flags: [String]
    var signed: Bool
}

/// The argument lists a stub program was run with.
private actor Calls {
    private(set) var all: [[String]] = []

    func append(_ argv: [String]) { all.append(argv) }
}
#endif
