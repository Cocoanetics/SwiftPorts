// `git lfs env`'s Endpoint lines against our resolver, one fixture repo
// at a time. Skipped where `git lfs version` doesn't run.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import SwiftGit
@testable import GitLFSKit

@Suite("git lfs env endpoints", .enabled(if: LFSOracle.isAvailable, "git-lfs is not on PATH"))
struct LFSEndpointOracleTests {
    let oracle = LFSOracle()

    private struct Fixture: Sendable {
        var name: String
        var remotes: [(name: String, url: String)]
        var config: [(key: String, value: String)] = []
        var lfsconfig: String?
        var commit: Bool = false
    }

    @Test("Endpoint= lines match")
    func endpoints() async throws {
        let fixtures = [
            Fixture(name: "https", remotes: [("origin", "https://example.com/a/b.git")]),
            Fixture(name: "nested", remotes: [("origin", "https://example.com/a/b/c.git")]),
            Fixture(name: "port", remotes: [("origin", "https://example.com:8443/a/b.git")]),
            Fixture(name: "slash", remotes: [("origin", "https://example.com/a/b.git/")]),
            Fixture(name: "nogit", remotes: [("origin", "https://example.com/a/b")]),
            Fixture(name: "ssh", remotes: [("origin", "ssh://git@example.com:9000/foo/bar")]),
            Fixture(name: "scp", remotes: [("origin", "git@example.com:foo/bar.git")]),
            Fixture(name: "bracket", remotes: [("origin", "[git@example.com:2222]:foo/bar.git")]),
            Fixture(name: "file", remotes: [("origin", "file:///tmp/not-a-repo")]),
            Fixture(
                name: "lfsurl",
                remotes: [("origin", "https://example.com/repo.git")],
                config: [("lfs.url", "https://lfs.example/custom")]),
            Fixture(
                name: "instead",
                remotes: [("origin", "https://github.com/org/repo.git")],
                config: [("url.https://lfs.example/.insteadof", "https://github.com/")]),
            Fixture(
                name: "two",
                remotes: [("origin", "https://example.com/o.git"), ("upstream", "https://example.com/u.git")],
                config: [("branch.main.remote", "upstream")],
                commit: true),
            Fixture(
                name: "lfsconfig",
                remotes: [("origin", "https://example.com/repo.git")],
                lfsconfig: "[lfs]\n\turl = https://file.example/from-file\n")
        ]
        try await oracle.host.run {
            for fixture in fixtures {
                let made = try await LFSFixture.make(
                    oracle.host, fixture.name,
                    remotes: fixture.remotes, config: fixture.config,
                    lfsconfig: fixture.lfsconfig, commit: fixture.commit)
                let ours = await LFSEndpointFinder(made.client).environmentEndpoints()
                let env = try oracle.lfsEnvironment(in: made.directory)
                let theirs = env.filter { $0.key == "Endpoint" || $0.key.hasPrefix("Endpoint (") }
                #expect(ours == theirs, "\(fixture.name)")
            }
        }
    }
}
#endif
