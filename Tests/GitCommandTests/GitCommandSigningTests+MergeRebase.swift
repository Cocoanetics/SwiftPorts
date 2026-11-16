// Exercise the shell environment all the way through GitClient into GitKit.
// Different identities, dates and offsets catch a shared author/committer
// signature as well as accidentally reading the test process's environment.
#if os(macOS) || os(Linux)
import Foundation
import Testing

extension GitCommandSigningTests {
    private static let mergeRebaseEnvironment = [
        "GIT_AUTHOR_NAME": "Merge Author", "GIT_AUTHOR_EMAIL": "author@example.com",
        "GIT_AUTHOR_DATE": "1770026400 +0530",
        "GIT_COMMITTER_NAME": "Committer", "GIT_COMMITTER_EMAIL": "committer@example.com",
        "GIT_COMMITTER_DATE": "1770030000 -0230",
        "GIT_MERGE_AUTOEDIT": "no", "GIT_EDITOR": "true", "LC_ALL": "C"
    ]

    private func parityCommit(_ file: String, text: String, in repo: URL) throws {
        try Data(text.utf8).write(to: repo.appendingPathComponent(file))
        try systemGit(["add", file], in: repo)
        try systemGit(["commit", "-q", "-m", file], in: repo)
    }

    /// Two side commits and one main commit; optionally conflict on `a`.
    private func parityRepository(in root: URL, key: String? = nil, conflict: Bool = false) throws -> URL {
        let repo = try makeRepository("repo", in: root, key: key)
        try systemGit(["checkout", "-q", "-b", "side"], in: repo)
        try parityCommit(conflict ? "a" : "b", text: "side\n", in: repo)
        try parityCommit("c", text: "second side commit\n", in: repo)
        try systemGit(["checkout", "-q", "main"], in: repo)
        try parityCommit(conflict ? "a" : "m", text: "main\n", in: repo)
        return repo
    }

    private func parityTwin(of repo: URL) throws -> URL {
        let oracle = repo.deletingLastPathComponent().appendingPathComponent("oracle")
        try FileManager.default.copyItem(at: repo, to: oracle)
        return oracle
    }

    private func expectObjectParity(_ repo: URL, _ oracle: URL, revisions: [String] = ["HEAD"]) throws {
        for rev in revisions {
            #expect(try systemGit(["rev-parse", rev], in: repo) == systemGit(["rev-parse", rev], in: oracle))
            #expect(try systemGit(["cat-file", "commit", rev], in: repo)
                == systemGit(["cat-file", "commit", rev], in: oracle))
        }
    }

    private func compareOperation(_ args: [String], in repo: URL, oracle: URL) async throws {
        let result = try await git(args, in: repo, environment: Self.mergeRebaseEnvironment)
        try #require(result.status == 0, "\(args): \(result.stderr)")
        try systemGit(args, in: oracle, environment: Self.mergeRebaseEnvironment)
        try expectObjectParity(repo, oracle)
    }

    @Test("merge --no-ff and merge -m write git's objects with separate environment signatures", arguments: [
        ["merge", "--no-ff", "side"], ["merge", "side", "-m", "Custom merge"]
    ])
    func mergeEnvironmentParity(args: [String]) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try parityRepository(in: root)
        let oracle = try parityTwin(of: repo)
        try await compareOperation(args, in: repo, oracle: oracle)
        let object = try systemGit(["cat-file", "commit", "HEAD"], in: repo)
        #expect(object.contains("\nauthor Merge Author <author@example.com> 1770026400 +0530\n"))
        #expect(object.contains("\ncommitter Committer <committer@example.com> 1770030000 -0230\n"))
    }

    @Test("rebase retains both original authors and uses the environment committer")
    func rebaseEnvironmentParity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try parityRepository(in: root)
        try systemGit(["checkout", "-q", "side"], in: repo)
        let authors = try systemGit(["log", "-2", "--format=%an <%ae> %at %ai"], in: repo)
        let oracle = try parityTwin(of: repo)
        try await compareOperation(["rebase", "main"], in: repo, oracle: oracle)
        try expectObjectParity(repo, oracle, revisions: ["HEAD^"])
        #expect(try systemGit(["log", "-2", "--format=%an <%ae> %at %ai"], in: repo) == authors)
    }

    @Test("merge -S and rebase -S write git's signed objects at fixed dates",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")),
          arguments: [false, true])
    func signedMergeRebaseEnvironmentParity(rebase: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (key, allowed) = try makeKey("alice", in: root)
        let repo = try parityRepository(in: root, key: key)
        try systemGit(["config", "gpg.ssh.allowedSignersFile", allowed], in: repo)
        if rebase { try systemGit(["checkout", "-q", "side"], in: repo) }
        let oracle = try parityTwin(of: repo)
        let args = rebase ? ["rebase", "-S", "main"] : ["merge", "-S", "--no-ff", "side"]
        try await compareOperation(args, in: repo, oracle: oracle)
        let revisions = rebase ? ["HEAD", "HEAD^"] : ["HEAD"]
        try expectObjectParity(repo, oracle, revisions: revisions)
        for rev in revisions {
            #expect(try run("git", ["verify-commit", rev], in: repo).status == 0)
        }
    }

    @Test("pull merge and pull --rebase write git's objects with the shell environment", arguments: [false, true])
    func pullEnvironmentParity(rebase: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try parityRepository(in: root)
        let remote = root.appendingPathComponent("remote")
        try FileManager.default.copyItem(at: repo, to: remote)
        try systemGit(["checkout", "-q", "side"], in: repo)
        try systemGit(["remote", "add", "origin", remote.path], in: repo)
        for (name, value) in [("branch.side.remote", "origin"), ("branch.side.merge", "refs/heads/main"),
                              ("pull.rebase", "false")] {
            try systemGit(["config", name, value], in: repo)
        }
        let oracle = try parityTwin(of: repo)
        try await compareOperation(rebase ? ["pull", "--rebase"] : ["pull"], in: repo, oracle: oracle)
        if rebase { try expectObjectParity(repo, oracle, revisions: ["HEAD^"]) }
    }

    @Test("annotated tag merges write git's objects and retain only signed mergetags",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen")),
          arguments: [false, true])
    func mergetagEnvironmentParity(signed: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (key, allowed) = try makeKey("alice", in: root)
        let repo = try parityRepository(in: root, key: key)
        try systemGit(["config", "gpg.ssh.allowedSignersFile", allowed], in: repo)
        try systemGit(["tag", signed ? "-s" : "-a", "release", "side", "-m", "Release\n\nDetails"], in: repo)
        let oracle = try parityTwin(of: repo)
        try await compareOperation(["merge", "--no-ff", "release"], in: repo, oracle: oracle)
        let object = try systemGit(["cat-file", "commit", "HEAD"], in: repo)
        #expect(object.contains("\nmergetag object ") == signed)
    }

    @Test("rebase --continue and --skip use the environment of the resumed shell", arguments: [false, true])
    func resumedRebaseEnvironmentParity(skip: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try parityRepository(in: root, conflict: true)
        try systemGit(["checkout", "-q", "side"], in: repo)
        let oracle = try parityTwin(of: repo)
        let stopped = try await git(["rebase", "main"], in: repo)
        try #require(stopped.status == 1, "\(stopped.stderr)")
        try #require(try run("git", ["rebase", "main"], in: oracle).status == 1)
        if !skip {
            for dir in [repo, oracle] {
                try Data("resolved\n".utf8).write(to: dir.appendingPathComponent("a"))
                try systemGit(["add", "a"], in: dir)
            }
        }
        try await compareOperation(["rebase", skip ? "--skip" : "--continue"], in: repo, oracle: oracle)
        if !skip { try expectObjectParity(repo, oracle, revisions: ["HEAD^"]) }
    }
}
#endif
