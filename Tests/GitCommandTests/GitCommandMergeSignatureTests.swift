// `git merge --verify-signatures` / `git pull --verify-signatures` and
// `merge.verifySignatures` (#170), after git's `verify_merge_signature`:
// every case runs in two identical copies of one repository, one through
// the system `git`, one through ours, and the two must print the same,
// exit the same and leave the same state — and a refused merge must leave
// HEAD, the index, the work tree, MERGE_HEAD and MERGE_MSG as they were.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
@testable import GitCommand

@Suite("git merge/pull --verify-signatures", .enabled(if: canSignWithSSHKeygen))
struct GitCommandMergeSignatureTests: SigningOracle {

    let host = IsolatedGitHost()

    /// One comparison: git commands run in both copies first, then `args`,
    /// with `environment` on top of both.
    struct Case: CustomStringConvertible {
        var setup: [[String]] = []
        var args: [String]
        var environment: [String: String] = [:]
        /// Whether git refuses, so nothing may change.
        var refused: Bool
        /// A merge into an unborn branch: GitKit's fast-forward detaches
        /// HEAD there, where git keeps the branch — a gap of its own, not
        /// the signature check's — so the branch isn't compared after.
        var intoUnborn = false
        /// Output only git 2.40 and newer gives (see ``systemGitIsModern``).
        var modernGitOnly = false

        var description: String { (setup.map { $0.joined(separator: " ") } + [args.joined(separator: " ")])
            .joined(separator: "; ") }
    }

    /// A repository under `root` whose `main` is one commit, with branches
    /// `good` (signed by a trusted key), `mal` (signed by an unknown key),
    /// `unsigned`, `bad` (a signed commit changed under its signature),
    /// `goodtop` (a trusted signed commit on `unsigned`), `unrelated` and
    /// `unrelatedmal` (root commits of their own, unsigned and signed by the
    /// unknown key) and tag `stag`, a trusted signed tag of `unsigned`.
    private func makeFixture(in root: URL) throws -> URL {
        let (alice, allowed) = try makeKey("alice", in: root)
        let (mallory, _) = try makeKey("mallory", in: root)
        let repo = try makeRepository("fixture", in: root, key: alice)
        try systemGit(["config", "gpg.ssh.allowedSignersFile", allowed], in: repo)
        for (branch, base, sign) in [("good", "main", ["-S"]), ("unsigned", "main", []),
                                     ("mal", "main", ["--gpg-sign=\(mallory)"]),
                                     ("goodtop", "unsigned", ["-S"])] {
            try systemGit(["checkout", "-q", "-b", branch, base], in: repo)
            try Data("\(branch)\n".utf8).write(to: repo.appendingPathComponent(branch))
            try systemGit(["add", "."], in: repo)
            try systemGit(["commit", "-q", "-m", branch] + sign, in: repo)
        }
        let signed = try systemGit(["cat-file", "commit", "good"], in: repo)
        let bad = try writeCommit(signed.replacingOccurrences(of: "\n\ngood", with: "\n\ntampered") + "\n", in: repo)
        try systemGit(["branch", "bad", bad], in: repo)
        try systemGit(["tag", "-s", "-m", "signed tag", "stag", "unsigned"], in: repo)
        // Histories with nothing in common with `main`: unsigned, and
        // signed by the unknown key.
        for (branch, sign) in [("unrelated", []), ("unrelatedmal", ["--gpg-sign=\(mallory)"])] {
            try systemGit(["checkout", "-q", "--orphan", branch], in: repo)
            try systemGit(["rm", "-rqf", "."], in: repo)
            try Data("\(branch)\n".utf8).write(to: repo.appendingPathComponent(branch))
            try systemGit(["add", branch], in: repo)
            try systemGit(["commit", "-q", "-m", branch] + sign, in: repo)
        }
        try systemGit(["checkout", "-q", "-f", "main"], in: repo)
        return repo
    }

    /// A copy of `repo` named `name` beside it.
    private func copy(_ repo: URL, as name: String) throws -> URL {
        let target = repo.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.copyItem(at: repo, to: target)
        return target
    }

    /// What a merge may change: HEAD and its branch, the index and work
    /// tree, MERGE_HEAD and MERGE_MSG.
    private func state(of repo: URL, exact: Bool) throws -> [String] {
        let head = try run("git", ["rev-parse", "-q", "--verify", "HEAD"], in: repo).out
        // A merge commit's id differs until #173: its tree and parents don't.
        let commit = exact ? head : try run("git", ["log", "-1", "--format=%T %P", "HEAD"], in: repo).out
        let branch = try run("git", ["symbolic-ref", "-q", "HEAD"], in: repo).out
        let status = try run("git", ["status", "--porcelain", "--untracked-files=all"], in: repo).out
        let index = try run("git", ["ls-files", "-s"], in: repo).out
        let files = try FileManager.default.contentsOfDirectory(atPath: repo.path).sorted().joined(separator: " ")
        let merge = ["MERGE_HEAD", "MERGE_MSG"].map {
            FileManager.default.fileExists(atPath: repo.path + "/.git/" + $0) ? $0 : "-"
        }
        return [commit, branch, status, index, files] + merge
    }

    /// Run `test` in two copies of `repo`, ours and git's, and compare.
    private func compare(_ test: Case, in repo: URL, index: Int) async throws {
        if test.modernGitOnly && !systemGitIsModern { return }
        let theirs = try copy(repo, as: "theirs-\(index)")
        let ours = try copy(repo, as: "ours-\(index)")
        for copy in [theirs, ours] {
            for args in test.setup { try systemGit(args, in: copy) }
        }
        let before = try state(of: ours, exact: true)
        let expected = try run("git", test.args, in: theirs, environment: test.environment)
        let actual = try await git(test.args, in: ours, environment: test.environment)
        #expect(actual.stdout == Self.portable(expected.out, theirs, ours), "stdout of \(test)")
        #expect(actual.stderr == Self.portable(expected.err, theirs, ours), "stderr of \(test)")
        #expect(actual.status == expected.status, "status of \(test)")
        var after = try state(of: ours, exact: false), expectedAfter = try state(of: theirs, exact: false)
        if test.intoUnborn && !test.refused { (after[1], expectedAfter[1]) = ("", "") }
        #expect(after == expectedAfter, "state after \(test)")
        if test.refused {
            #expect(expected.status != 0, "git refuses \(test)")
            #expect(try state(of: ours, exact: true) == before, "nothing changed by \(test)")
        }
    }

    /// git's output in copy `theirs` as it reads in copy `ours`.
    private static func portable(_ text: String, _ theirs: URL, _ ours: URL) -> String {
        text.replacingOccurrences(of: theirs.lastPathComponent, with: ours.lastPathComponent)
    }

    @Test("good, untrusted, bad and unsigned heads; a signed tag of an unsigned commit; -q; --ff-only")
    func mergeHeads() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeFixture(in: root)
        let local = ["commit", "-q", "--allow-empty", "-m", "local"]
        let cases: [Case] = [
            Case(args: ["merge", "--verify-signatures", "good"], refused: false),
            Case(args: ["merge", "--verify-signatures", "--no-ff", "-m", "merge good", "good"], refused: false),
            Case(args: ["merge", "-q", "--verify-signatures", "good"], refused: false),
            Case(args: ["merge", "--verify-signatures", "unsigned"], refused: true),
            Case(args: ["merge", "--verify-signatures", "--no-ff", "unsigned"], refused: true),
            Case(args: ["merge", "--verify-signatures", "mal"], refused: true),
            Case(args: ["merge", "--verify-signatures", "bad"], refused: true),
            Case(args: ["merge", "--verify-signatures", "stag"], refused: true),
            Case(args: ["merge", "-q", "--verify-signatures", "unsigned"], refused: true),
            // The signature is checked before the fast-forward is refused.
            Case(setup: [local], args: ["merge", "--ff-only", "--verify-signatures", "unsigned"], refused: true),
            Case(setup: [local], args: ["merge", "--ff-only", "--verify-signatures", "good"], refused: true,
                 modernGitOnly: true)
        ]
        for (index, test) in cases.enumerated() { try await compare(test, in: repo, index: index) }
    }

    @Test("up to date, reduced and octopus heads, and an unborn branch")
    func reducedAndUnborn() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeFixture(in: root)
        let orphan: [[String]] = [["checkout", "-q", "--orphan", "orphan"], ["rm", "-rqf", "."]]
        let cases: [Case] = [
            // HEAD has the unsigned commit already: nothing is verified.
            Case(setup: [["checkout", "-q", "unsigned"]], args: ["merge", "--verify-signatures", "main"],
                 refused: false),
            Case(setup: [["checkout", "-q", "goodtop"]], args: ["merge", "--verify-signatures", "unsigned"],
                 refused: false),
            // `unsigned` is reduced away by `goodtop`, which is verified.
            Case(args: ["merge", "--verify-signatures", "unsigned", "goodtop"], refused: false),
            Case(args: ["merge", "--verify-signatures", "good", "unsigned"], refused: true),
            // No merge base: verified all the same, before anything else.
            Case(args: ["merge", "--verify-signatures", "unrelated"], refused: true),
            Case(args: ["merge", "--verify-signatures", "unrelatedmal"], refused: true),
            Case(setup: [["config", "merge.verifySignatures", "true"]], args: ["merge", "unrelated"], refused: true),
            Case(args: ["merge", "--verify-signatures", "unsigned", "good"], refused: true),
            Case(args: ["merge", "--verify-signatures", "-m", "octopus", "good", "goodtop"], refused: false),
            Case(setup: orphan, args: ["merge", "--verify-signatures", "unsigned"], refused: true),
            Case(setup: orphan, args: ["merge", "--verify-signatures", "good"], refused: false, intoUnborn: true)
        ]
        for (index, test) in cases.enumerated() { try await compare(test, in: repo, index: index) }
    }

    @Test("merge.verifySignatures, the flags and GIT_CONFIG_COUNT: git's precedence")
    func precedence() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeFixture(in: root)
        let on = [["config", "merge.verifySignatures", "true"]]
        let off = [["config", "merge.verifySignatures", "false"]]
        let command = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "merge.verifySignatures",
                       "GIT_CONFIG_VALUE_0": "true"]
        let cases: [Case] = [
            Case(args: ["merge", "unsigned"], refused: false),
            Case(setup: on, args: ["merge", "unsigned"], refused: true),
            Case(setup: on, args: ["merge", "good"], refused: false),
            Case(setup: on, args: ["merge", "--no-verify-signatures", "unsigned"], refused: false),
            Case(setup: off, args: ["merge", "--verify-signatures", "unsigned"], refused: true),
            Case(args: ["merge", "--verify-signatures", "--no-verify-signatures", "unsigned"], refused: false),
            Case(args: ["merge", "--no-verify-signatures", "--verify-signatures", "unsigned"], refused: true),
            Case(setup: off, args: ["merge", "unsigned"], environment: command, refused: true)
        ]
        for (index, test) in cases.enumerated() { try await compare(test, in: repo, index: index) }
    }

    @Test("gpg.minTrustLevel turns git's own trust check off; the check's minimum decides")
    func trust() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeFixture(in: root)
        let cases: [Case] = [
            Case(setup: [["config", "gpg.minTrustLevel", "undefined"]], args: ["merge", "--verify-signatures", "mal"],
                 refused: true),
            Case(setup: [["config", "gpg.minTrustLevel", "fully"]], args: ["merge", "--verify-signatures", "good"],
                 refused: false),
            Case(setup: [["config", "gpg.minTrustLevel", "ultimate"]], args: ["merge", "--verify-signatures", "good"],
                 refused: true),
            // A verifier git can't find: its message, then no signature.
            Case(setup: [["config", "gpg.ssh.program", "no-such-keygen-170"]],
                 args: ["merge", "--verify-signatures", "good"], refused: true)
        ]
        for (index, test) in cases.enumerated() { try await compare(test, in: repo, index: index) }
    }

    @Test("pull: merge, fast-forward, rebase, octopus, quiet and unborn")
    func pull() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = try makeFixture(in: root)
        let clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try systemGit(["init", "-q", "-b", "main"], in: clone)
        for (key, value) in [("user.name", "Test"), ("user.email", "test@example.com"), ("gpg.format", "ssh"),
                             ("gpg.ssh.allowedSignersFile", root.appendingPathComponent("allowed-alice").path)] {
            try systemGit(["config", key, value], in: clone)
        }
        let unborn = try copy(clone, as: "unborn")
        try systemGit(["pull", "-q", remote.path, "main"], in: clone)
        // A commit of its own to rebase (GitKit's rebase can't replay an
        // empty one).
        try systemGit(["checkout", "-q", "-b", "local"], in: clone)
        try Data("local\n".utf8).write(to: clone.appendingPathComponent("local"))
        try systemGit(["add", "."], in: clone)
        try systemGit(["commit", "-q", "-m", "local"], in: clone)
        try systemGit(["checkout", "-q", "main"], in: clone)
        let local = ["reset", "-q", "--hard", "local"]
        let on = ["config", "merge.verifySignatures", "true"]
        let pull = ["pull", "--no-rebase", remote.path]
        let rebase = ["pull", "--rebase", remote.path]
        let cases: [Case] = [
            Case(args: ["pull", "--verify-signatures", remote.path, "unsigned"], refused: true),
            Case(args: ["pull", "--verify-signatures", remote.path, "good"], refused: false),
            Case(args: ["pull", "-q", "--verify-signatures", remote.path, "good"], refused: false),
            Case(setup: [on], args: pull + ["unsigned"], refused: true),
            Case(setup: [on], args: pull + ["--no-verify-signatures", "unsigned"], refused: false),
            Case(args: pull + ["--verify-signatures", "good", "unsigned"], refused: true),
            Case(args: pull + ["--verify-signatures", "unsigned", "goodtop"], refused: false),
            // A rebase ignores the option, and says so when told it.
            Case(setup: [local], args: rebase + ["--verify-signatures", "unsigned"], refused: false,
                 modernGitOnly: true),
            Case(setup: [local, on], args: rebase + ["unsigned"], refused: false, modernGitOnly: true),
            Case(setup: [local], args: rebase + ["--no-verify-signatures", "unsigned"], refused: false,
                 modernGitOnly: true),
            // A rebase that fast-forwards merges, and verifies.
            Case(args: rebase + ["--verify-signatures", "unsigned"], refused: true),
            Case(args: rebase + ["--verify-signatures", "good"], refused: false)
        ]
        for (index, test) in cases.enumerated() { try await compare(test, in: clone, index: index) }

        // Into an unborn branch, either flag verifies, the config doesn't.
        let unbornCases: [Case] = [
            Case(args: ["pull", "--verify-signatures", remote.path, "unsigned"], refused: true),
            Case(args: ["pull", "--no-verify-signatures", remote.path, "unsigned"], refused: true),
            Case(setup: [on], args: ["pull", remote.path, "unsigned"], refused: false),
            Case(args: ["pull", "-q", "--verify-signatures", remote.path, "good"], refused: false),
            Case(args: ["pull", "--verify-signatures", remote.path, "good"], refused: false)
        ]
        for (index, var test) in unbornCases.enumerated() {
            test.intoUnborn = true
            try await compare(test, in: unborn, index: 100 + index)
        }
    }

    @Test("the verifier runs through the shell's launcher: refused, or found nowhere, as git's missing program")
    func launcher() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try makeFixture(in: root)
        let head = try systemGit(["rev-parse", "HEAD"], in: repo)
        let denied = try await git(["merge", "--verify-signatures", "good"], in: repo,
                                   launcher: SandboxedDenyLauncher(reason: "no processes"))
        let abbreviation = try systemGit(["rev-parse", "--short", "good"], in: repo)
        #expect(denied.stdout == "")
        // As git, which can run neither ssh-keygen -Y find-principals nor
        // -Y check-novalidate, and so takes the signature for a bad one.
        let refusal = "error: cannot run ssh-keygen: Operation not permitted (no processes)\n"
        #expect(denied.stderr == refusal + refusal
            + "fatal: Commit \(abbreviation) has a bad GPG signature allegedly by (null).\n")
        #expect(denied.status == 128)

        let launcher = NothingRunsLauncher()
        let unresolved = try await git(["merge", "--verify-signatures", "good"], in: repo, launcher: launcher)
        let missing = "error: cannot run ssh-keygen: No such file or directory\n"
        #expect(unresolved.stderr == missing + missing
            + "fatal: Commit \(abbreviation) has a bad GPG signature allegedly by (null).\n")
        #expect(unresolved.status == 128)
        #expect(await launcher.launches == [.name("ssh-keygen"), .name("ssh-keygen")])
        #expect(try systemGit(["rev-parse", "HEAD"], in: repo) == head)
        #expect(try systemGit(["status", "--porcelain"], in: repo) == "")
    }
}

/// A launcher with nothing to run: it records each executable and throws
/// ``ProcessLaunchUnresolved``, as a chain with no fallback does.
private actor NothingRunsLauncher: ProcessLauncher {
    private(set) var launches: [Executable] = []

    func launch(
        _ executable: Executable, arguments: Arguments, environment: Environment,
        workingDirectory: String?, input: InputSource, output: OutputSink, error: OutputSink
    ) async throws -> ExecutionRecord {
        launches.append(executable)
        throw ProcessLaunchUnresolved(executable: executable)
    }
}
#endif
