// The tags a merge commit carries in `mergetag` headers, as `git log` /
// `git show --show-signature` show them (#170, git's `show_mergetag`):
// what each tag names among the parents, and its signature's check —
// compared with the system `git` over merges it made and commits crafted
// from them.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
@testable import GitCommand

@Suite("git log/show --show-signature: mergetag", .enabled(if: canSignWithSSHKeygen))
struct GitCommandMergetagTests: SigningOracle {

    let host = IsolatedGitHost()

    /// A repository whose merges carry mergetags, and the commits to
    /// show: system git's own merges (`merged`, an octopus), and commits
    /// crafted from `merged`'s text.
    private func makeFixture(in root: URL) throws -> (repo: URL, commits: [String: String]) {
        let (alice, allowed) = try makeKey("alice", in: root)
        let (mallory, _) = try makeKey("mallory", in: root)
        let repo = try makeRepository("repo", in: root, key: alice)
        try systemGit(["config", "gpg.ssh.allowedSignersFile", allowed], in: repo)
        for branch in ["good", "other", "unrelated"] {
            try systemGit(["checkout", "-q", "-b", branch, "main"], in: repo)
            try Data("\(branch)\n".utf8).write(to: repo.appendingPathComponent(branch))
            try systemGit(["add", "."], in: repo)
            try systemGit(["commit", "-q", "-m", branch], in: repo)
        }
        try systemGit(["tag", "-s", "-m", "release 1", "v1", "good"], in: repo)
        try systemGit(["tag", "-s", "--local-user=\(mallory)", "-m", "other", "mt", "other"], in: repo)
        try systemGit(["checkout", "-q", "main"], in: repo)
        var commits: [String: String] = [:]
        try systemGit(["merge", "-q", "--no-ff", "-m", "merge v1", "v1"], in: repo)
        commits["merged"] = try systemGit(["rev-parse", "HEAD"], in: repo)
        try systemGit(["checkout", "-q", "-b", "octopus", "main~1"], in: repo)
        try systemGit(["merge", "-q", "--no-ff", "-m", "octopus", "v1", "mt"], in: repo)
        commits["octopus"] = try systemGit(["rev-parse", "HEAD"], in: repo)
        try systemGit(["checkout", "-q", "main"], in: repo)

        let merged = try systemGit(["cat-file", "commit", commits["merged"] ?? ""], in: repo) + "\n"
        let good = try systemGit(["rev-parse", "good"], in: repo)
        let parent = try systemGit(["rev-parse", "main~1"], in: repo)
        let unrelated = try systemGit(["rev-parse", "unrelated"], in: repo)
        let ownTree = try systemGit(["rev-parse", "\(commits["merged"] ?? "")^{tree}"], in: repo)
        let parentTree = try systemGit(["rev-parse", "main~1^{tree}"], in: repo)
        /// `merged`'s mergetag naming `object` as a `type`.
        func retarget(_ object: String, as type: String) -> (String) -> String {
            { $0.replacingOccurrences(of: "mergetag object \(good)\n type commit\n",
                                      with: "mergetag object \(object)\n type \(type)\n") }
        }
        let crafted: [(String, (String) -> String)] = [
            ("firstParent", { $0.replacingOccurrences(of: "mergetag object \(good)",
                                                      with: "mergetag object \(parent)") }),
            ("nonParent", { $0.replacingOccurrences(of: "mergetag object \(good)",
                                                    with: "mergetag object \(unrelated)") }),
            ("malformed", { $0.replacingOccurrences(of: "mergetag object \(good)", with: "mergetag garbage") }),
            // A type git already knows the object not to be: the second
            // parent, the commit's tree, a parent's tree (known to `log`'s
            // walk, not to `show`); one it doesn't know yet is no error.
            ("secondParentAsTree", retarget(good, as: "tree")),
            ("secondParentAsTag", retarget(good, as: "tag")),
            ("ownTreeAsCommit", retarget(ownTree, as: "commit")),
            ("parentTreeAsCommit", retarget(parentTree, as: "commit")),
            ("unrelatedAsTree", retarget(unrelated, as: "tree")),
            ("unknownType", { $0.replacingOccurrences(of: "\n type commit\n", with: "\n type bogus\n") }),
            ("noName", { $0.replacingOccurrences(of: "\n tag v1\n", with: "\n tagx v1\n") }),
            ("tampered", { $0.replacingOccurrences(of: "\n release 1\n", with: "\n release 2\n") }),
            ("noTagger", { text in
                text.split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.hasPrefix(" tagger ") }.joined(separator: "\n")
            }),
            ("unsigned", { text in
                guard let start = text.range(of: " -----BEGIN SSH SIGNATURE-----\n"),
                      let end = text.range(of: " -----END SSH SIGNATURE-----\n") else { return text }
                return text.replacingCharacters(in: start.lowerBound..<end.upperBound, with: "")
            })
        ]
        for (name, edit) in crafted {
            let text = edit(merged)
            #expect(text != merged, "\(name) is crafted")
            commits[name] = try writeCommit(text, in: repo)
        }
        return (repo, commits)
    }

    /// `show`'s output up to its diff: git shows a merge's combined diff,
    /// which this port doesn't, and that isn't what's compared here.
    private static func header(_ show: String) -> String {
        show.components(separatedBy: "\ndiff --git ")[0]
            .trimmingCharacters(in: .newlines)
    }

    @Test("merged, octopus, first-parent, non-parent, malformed, bad, unknown key, unsigned and taggerless tags")
    func mergetagsMatchGit() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, commits) = try makeFixture(in: root)
        // git before 2.40 runs the verifier for a tag without a tagger.
        for name in commits.keys.sorted() where systemGitIsModern || name != "noTagger" {
            let commit = try #require(commits[name])
            for args in [["log", "-1", "--show-signature", commit],
                         ["log", "-1", "--show-signature", "--oneline", commit],
                         ["log", "-1", "--show-signature", "--format=%h %s", commit],
                         ["log", "-1", commit],
                         ["show", "--show-signature", commit]] {
                let ours = try await git(args, in: repo)
                let theirs = try run("git", args, in: repo)
                if args[0] == "show" {
                    #expect(Self.header(ours.stdout) == Self.header(theirs.out), "stdout of \(name): \(args)")
                } else {
                    #expect(ours.stdout == theirs.out, "stdout of \(name): \(args)")
                }
                #expect(ours.stderr == theirs.err, "stderr of \(name): \(args)")
                #expect(ours.status == theirs.status, "status of \(name): \(args)")
            }
        }
        // Without --show-signature, nothing of the tags.
        let plain = try await git(["log", "-1", try #require(commits["merged"])], in: repo)
        #expect(!plain.stdout.contains("merged tag"))
    }

    @Test("log.showSignature, from the config or GIT_CONFIG_COUNT, shows them; --no-show-signature doesn't")
    func configuredShowSignature() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, commits) = try makeFixture(in: root)
        let merged = try #require(commits["merged"])
        let command = ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "log.showSignature", "GIT_CONFIG_VALUE_0": "true"]
        for (args, environment) in [(["log", "-1", merged], command),
                                    (["log", "-1", "--no-show-signature", merged], command)] {
            let ours = try await git(args, in: repo, environment: environment)
            let theirs = try run("git", args, in: repo, environment: environment)
            #expect(ours.stdout == theirs.out, "\(args)")
            #expect(ours.stderr == theirs.err, "\(args)")
        }
        try systemGit(["config", "log.showSignature", "true"], in: repo)
        let ours = try await git(["log", "-1", merged], in: repo)
        #expect(ours.stdout == (try run("git", ["log", "-1", merged], in: repo).out))
        #expect(ours.stdout.contains("merged tag 'v1'\nGood \"git\" signature"))
    }

    @Test("a tag read from the commit alone: no tag object needed")
    func tagObjectAbsent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, commits) = try makeFixture(in: root)
        let merged = try #require(commits["merged"])
        // The tag goes, its loose object too.
        let tag = try systemGit(["rev-parse", "v1"], in: repo)
        try systemGit(["tag", "-d", "v1"], in: repo)
        let object = repo.appendingPathComponent(".git/objects/\(tag.prefix(2))/\(tag.dropFirst(2))")
        try FileManager.default.removeItem(at: object)
        #expect(try run("git", ["cat-file", "-e", tag], in: repo).status != 0)
        let args = ["log", "-1", "--show-signature", merged]
        let ours = try await git(args, in: repo)
        let theirs = try run("git", args, in: repo)
        #expect(ours.stdout == theirs.out)
        #expect(ours.stderr == theirs.err)
        #expect(ours.stdout.contains("merged tag 'v1'\nGood \"git\" signature"))
    }

    @Test("the tag's verifier runs through the shell's launcher, as git's missing program when refused")
    func launcher() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (repo, commits) = try makeFixture(in: root)
        let merged = try #require(commits["merged"])
        let denied = try await git(["log", "-1", "--show-signature", "--format=%h", merged], in: repo,
                                   launcher: SandboxedDenyLauncher(reason: "no processes"))
        let refusal = "error: cannot run ssh-keygen: Operation not permitted (no processes)\n"
        #expect(denied.stderr == refusal + refusal)
        #expect(denied.stdout.hasPrefix("merged tag 'v1'\n"))
        #expect(denied.status == 0)

        // A verifier git can't find either: what git says then.
        try systemGit(["config", "gpg.ssh.program", "no-such-keygen-170"], in: repo)
        let args = ["log", "-1", "--show-signature", "--format=%h", merged]
        let ours = try await git(args, in: repo)
        let theirs = try run("git", args, in: repo)
        #expect(ours.stdout == theirs.out)
        #expect(ours.stderr == theirs.err)
        #expect(ours.status == theirs.status)
    }
}
#endif
