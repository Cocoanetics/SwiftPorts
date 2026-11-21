#if os(macOS) || os(Linux)
import Foundation
import Testing

@Suite("git lfs status same-path oracle",
       .enabled(if: LFSSamePathOracle.isAvailable, "git-lfs 3.7.1 is not on PATH"))
struct GitCommandLFSStatusOracleTests {
    @Test func formatsTrackingAndSubdirectory() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("status")
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("old.dat", "alpha", in: repo)
        try oracle.write("plain.txt", "ordinary", in: repo)
        try oracle.add([".gitattributes", "old.dat", "plain.txt"], in: repo)
        try oracle.commit("base", in: repo)
        try oracle.git(["update-ref", "refs/remotes/upstream/topic", "HEAD"], in: repo)
        try oracle.git(["config", "branch.main.remote", "upstream"], in: repo)
        try oracle.git(["config", "branch.main.merge", "refs/heads/topic"], in: repo)
        try oracle.git(["config", "branch.main.pushRemote", "push-only"], in: repo)
        try oracle.write("pushed.dat", "committed media", in: repo)
        try oracle.add(["pushed.dat"], in: repo)
        try oracle.commit("ahead", in: repo)
        try oracle.git(["mv", "old.dat", "new.dat"], in: repo)
        try oracle.write("new.dat", "changed after staging", in: repo)
        try oracle.write("added.dat", "new media", in: repo)
        try oracle.write("plain.txt", "ordinary staged", in: repo)
        try oracle.add(["added.dat", "plain.txt"], in: repo)
        try oracle.write("plain.txt", "ordinary unstaged", in: repo)
        let subdir = repo.appendingPathComponent("nested/deep")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        for cwd in [repo, subdir] {
            for flags in [[], ["-p"], ["--porcelain"], ["-j"], ["--json"], ["-p", "-j"], ["ignored", "args"]] {
                try await oracle.compare(["status"] + flags, in: cwd)
            }
        }
        try oracle.git(["checkout", "--detach", "-q"], in: repo)
        try await oracle.compare(["status"], in: repo)
    }

    @Test func unbornAndRepositoryErrors() async throws {
        let oracle = try LFSSamePathOracle()
        defer { oracle.cleanup() }
        let repo = try oracle.repository("unborn")
        for flags in [[], ["-p"], ["-j"]] { try await oracle.compare(["status"] + flags, in: repo) }
        try oracle.track(["*.dat"], in: repo)
        try oracle.write("added.dat", "media", in: repo)
        try oracle.add([".gitattributes", "added.dat"], in: repo)
        for flags in [[], ["-p"], ["-j"]] { try await oracle.compare(["status"] + flags, in: repo) }
        let bare = try oracle.repository("bare", bare: true)
        try await oracle.compare(["status"], in: bare)
        try await oracle.compare(["status"], in: oracle.home)
    }
}
#endif
