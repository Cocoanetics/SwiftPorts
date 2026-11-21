#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("git lfs status same-path oracle",
       .enabled(if: LFSSamePathOracle.isAvailable, LFSCommandFixture.unavailableReason))
struct GitCommandLFSStatusOracleTests {
    static let allForms: [[String]] = [
        [], ["-p"], ["--porcelain"], ["-j"], ["--json"], ["-p", "-j"], ["--porcelain", "--json"]
    ]

    static let coreForms: [[String]] = [[], ["-p"], ["-j"]]

    @Test func statusSectionsAndMachineForms() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("sections")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("base.dat", "base payload", in: repo)
        try oracle.write("dirty.dat", "initial dirty", in: repo)
        try oracle.add([".gitattributes", "base.dat", "dirty.dat"], in: repo)
        try oracle.commit("base", in: repo)
        try oracle.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: repo)
        try oracle.git(["config", "branch.main.remote", "origin"], in: repo)
        try oracle.git(["config", "branch.main.merge", "refs/heads/main"], in: repo)
        try oracle.write("unpushed.dat", "unpushed media", in: repo)
        try oracle.add(["unpushed.dat"], in: repo)
        try oracle.commit("unpushed pointer", in: repo)
        try oracle.write("staged.dat", "staged media", in: repo)
        try oracle.add(["staged.dat"], in: repo)
        try oracle.write("dirty.dat", "unstaged modification", in: repo)

        for flags in Self.allForms + [["ignored", "args"]] {
            let output = try await oracle.compare(["status"] + flags, in: repo)
            if flags.isEmpty {
                #expect(output.stdout.contains("Objects to be pushed to origin/main:\n"))
                #expect(output.stdout.contains("\tunpushed.dat ("))
                #expect(output.stdout.contains("\tstaged.dat (LFS: "))
                #expect(output.stdout.contains("\tdirty.dat (LFS: "))
            }
        }
    }

    @Test func trackingRefResolutionAndDetachedHead() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("tracking")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("base.dat", "base", in: repo)
        try oracle.add([".gitattributes", "base.dat"], in: repo)
        try oracle.commit("base", in: repo)
        try oracle.git(["update-ref", "refs/remotes/upstream/topic", "HEAD"], in: repo)
        try oracle.write("first.dat", "first ahead", in: repo)
        try oracle.add(["first.dat"], in: repo)
        try oracle.commit("first", in: repo)
        try oracle.git(["update-ref", "refs/remotes/upstream/main", "HEAD"], in: repo)
        try oracle.write("second.dat", "second ahead", in: repo)
        try oracle.add(["second.dat"], in: repo)
        try oracle.commit("second", in: repo)
        // Competing push remotes point at HEAD so using them would hide unpushed objects.
        try oracle.git(["update-ref", "refs/remotes/push-only/main", "HEAD"], in: repo)
        try oracle.git(["update-ref", "refs/remotes/push-default/main", "HEAD"], in: repo)
        try oracle.git(["config", "branch.main.pushRemote", "push-only"], in: repo)
        try oracle.git(["config", "remote.pushDefault", "push-default"], in: repo)

        // No upstream configured.
        try await compareForms(oracle, Self.coreForms, in: repo)

        // Missing tracking ref.
        try oracle.git(["config", "branch.main.remote", "upstream"], in: repo)
        try oracle.git(["config", "branch.main.merge", "refs/heads/missing"], in: repo)
        try await compareForms(oracle, Self.coreForms, in: repo)

        // Renamed merge branch relative to local branch, ignoring competing push remotes.
        try oracle.git(["config", "branch.main.merge", "refs/heads/topic"], in: repo)
        let renamed = try await oracle.compare(["status"], in: repo)
        #expect(renamed.stdout.contains("Objects to be pushed to upstream/topic:\n"))
        #expect(renamed.stdout.contains("\tfirst.dat (") && renamed.stdout.contains("\tsecond.dat ("))

        // Non-refs/heads/ and empty/missing merge values fall back to <remote>/<local-branch>.
        for merge in ["refs/tags/topic", "topic", ""] {
            try oracle.git(["config", "branch.main.merge", merge], in: repo)
            let fallback = try await oracle.compare(["status"], in: repo)
            #expect(fallback.stdout.contains("Objects to be pushed to upstream/main:\n"))
        }
        try oracle.git(["config", "--unset", "branch.main.merge"], in: repo)
        let unset = try await oracle.compare(["status"], in: repo)
        #expect(unset.stdout.contains("Objects to be pushed to upstream/main:\n"))

        // Detached HEAD prints "On branch HEAD" and no pushed section.
        try oracle.git(["checkout", "--detach", "-q"], in: repo)
        for flags in Self.coreForms {
            let detached = try await oracle.compare(["status"] + flags, in: repo)
            if flags.isEmpty {
                #expect(detached.stdout.hasPrefix("On branch HEAD\n\n"))
            }
        }
    }

    @Test func cleanStatesOrdinaryUntrackedAndSameSizeEdits() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("clean-and-samesize")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("smudged.dat", "alpha-1", in: repo)
        try oracle.write("pointer-only.dat", "pointer-target", in: repo)
        try oracle.write("perm.dat", "permissions", in: repo)
        try oracle.write("exec.dat", "executable", in: repo)
        try oracle.write("plain.txt", "ordinary", in: repo)
        try oracle.add(
            [".gitattributes", "smudged.dat", "pointer-only.dat", "perm.dat", "exec.dat", "plain.txt"],
            in: repo)
        try oracle.commit("base", in: repo)

        // Check out pointer-only.dat with smudge skipped so the worktree holds raw pointer bytes cleanly.
        try FileManager.default.removeItem(at: repo.appendingPathComponent("pointer-only.dat"))
        try oracle.git([
            "-c", "filter.lfs.process=git-lfs filter-process --skip",
            "-c", "filter.lfs.smudge=git-lfs smudge --skip -- %f",
            "checkout", "--", "pointer-only.dat"
        ], in: repo)
        // Non-executable permission change (0400) stays clean, matching upstream t-status.sh.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: repo.appendingPathComponent("perm.dat").path)
        // Untracked files (both LFS-tracked pattern and ordinary) are excluded.
        try oracle.write("untracked.dat", "untracked media", in: repo)
        try oracle.write("untracked.txt", "untracked plain", in: repo)

        for flags in Self.coreForms {
            let clean = try await oracle.compare(["status"] + flags, in: repo)
            if flags == ["-j"] { #expect(clean.stdout == "{\"files\":{}}\n") }
            if flags == ["-p"] { #expect(clean.stdout.isEmpty) }
        }

        // Same-size edit on committed smudged file, ordinary modification, duplicate-content LFS files,
        // and executable mode change.
        try oracle.write("smudged.dat", "alpha-2", in: repo)
        try oracle.write("plain.txt", "ordinary staged", in: repo)
        try oracle.write("dup1.dat", "identical", in: repo)
        try oracle.write("dup2.dat", "identical", in: repo)
        try oracle.add(["plain.txt", "dup1.dat", "dup2.dat"], in: repo)
        try oracle.write("plain.txt", "ordinary unstaged", in: repo)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: repo.appendingPathComponent("exec.dat").path)

        try await compareForms(oracle, Self.allForms, in: repo)
    }

    @Test func partiallyStagedAndBaselineReversions() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("partial-revert")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("mod.dat", "v1-data", in: repo)
        try oracle.write("wt-revert.dat", "base-bytes", in: repo)
        try oracle.write("idx-revert.dat", "base-bytes", in: repo)
        try oracle.add([".gitattributes", "mod.dat", "wt-revert.dat", "idx-revert.dat"], in: repo)
        try oracle.commit("base", in: repo)

        // Partially staged addition: staged part 1, then worktree edited to part 2 (same size).
        try oracle.write("added.dat", "part 1", in: repo)
        try oracle.add(["added.dat"], in: repo)
        try oracle.write("added.dat", "part 2", in: repo)

        // Partially staged modification: HEAD v1, index v2, worktree v3 (same size).
        try oracle.write("mod.dat", "v2-data", in: repo)
        try oracle.add(["mod.dat"], in: repo)
        try oracle.write("mod.dat", "v3-data", in: repo)

        // Index holds staged v2, worktree reverted back to HEAD's v1 bytes.
        try oracle.write("wt-revert.dat", "staged-new", in: repo)
        try oracle.add(["wt-revert.dat"], in: repo)
        try oracle.write("wt-revert.dat", "base-bytes", in: repo)

        // Index staged then reset back to HEAD while worktree keeps new bytes.
        try oracle.write("idx-revert.dat", "worktree-new", in: repo)
        try oracle.add(["idx-revert.dat"], in: repo)
        try oracle.git(["reset", "-q", "HEAD", "--", "idx-revert.dat"], in: repo)

        try await compareForms(oracle, Self.allForms, in: repo)
    }

    @Test func formatsTrackingAndSubdirectory() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("status")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("old.dat", "alpha", in: repo)
        try oracle.write("nested/keep.dat", "inside nested", in: repo)
        try oracle.write("plain.txt", "ordinary", in: repo)
        try oracle.add([".gitattributes", "old.dat", "nested/keep.dat", "plain.txt"], in: repo)
        try oracle.commit("base", in: repo)
        try oracle.git(["update-ref", "refs/remotes/upstream/topic", "HEAD"], in: repo)
        try oracle.git(["config", "branch.main.remote", "upstream"], in: repo)
        try oracle.git(["config", "branch.main.merge", "refs/heads/topic"], in: repo)
        try oracle.git(["config", "branch.main.pushRemote", "push-only"], in: repo)
        try oracle.write("pushed.dat", "committed media", in: repo)
        try oracle.add(["pushed.dat"], in: repo)
        try oracle.commit("ahead", in: repo)
        try oracle.git(["mv", "old.dat", "nested/new.dat"], in: repo)
        try oracle.write("nested/new.dat", "changed after staging", in: repo)
        try oracle.write("nested/keep.dat", "modified nested", in: repo)
        try oracle.write("added.dat", "new media", in: repo)
        try oracle.write("plain.txt", "ordinary staged", in: repo)
        try oracle.add(["added.dat", "plain.txt"], in: repo)
        try oracle.write("plain.txt", "ordinary unstaged", in: repo)
        let subdir = repo.appendingPathComponent("nested/deep")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        for cwd in [repo, subdir] {
            for flags in Self.allForms + [["ignored", "args"]] {
                try await oracle.compare(["status"] + flags, in: cwd)
            }
        }
    }

    @Test func unbornAndRepositoryErrors() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("unborn")
        try await compareForms(oracle, Self.coreForms, in: repo)
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("added.dat", "media", in: repo)
        try oracle.write("plain.txt", "ordinary", in: repo)
        try oracle.add([".gitattributes", "added.dat", "plain.txt"], in: repo)
        try await compareForms(oracle, Self.allForms, in: repo)

        let bare = try oracle.repository("bare", bare: true)
        try await compareForms(oracle, Self.coreForms, in: bare)
        try await compareForms(oracle, Self.coreForms, in: oracle.home)
    }

    func compareForms(_ oracle: LFSSamePathOracle, _ forms: [[String]], in cwd: URL) async throws {
        for flags in forms {
            try await oracle.compare(["status"] + flags, in: cwd)
        }
    }
}
#endif
