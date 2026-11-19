import Foundation
import Testing
import SwiftGit
@testable import GitLFSKit

/// One row of the endpoint table. `url` is what `lfs.url` / a remote / a
/// derived clone URL must resolve to for `operation`.
private struct EndpointRow: Sendable {
    var name: String
    var operation: String = "download"
    var remote: String = ""
    var remotes: [(name: String, url: String)] = [("origin", "https://example.com/repo.git")]
    var config: [(key: String, value: String)] = []
    var lfsconfig: String?
    var url: String
    var user: String?
    var host: String?
    var port: String?
    var path: String?
    var userAndHost: String?
}

@Suite("LFS endpoint resolution")
struct EndpointResolutionTests {
    let host = IsolatedLFSHost()

    private static let rows: [EndpointRow] = [
        EndpointRow(
            name: "lfs.url wins over a named remote's lfsurl",
            remote: "upstream",
            remotes: [
                ("origin", "https://example.com/repo.git"),
                ("upstream", "https://example.com/other.git")
            ],
            config: [
                ("lfs.url", "https://lfs.example/custom"),
                ("remote.upstream.lfsurl", "https://other.example/lfs")
            ],
            url: "https://lfs.example/custom"),
        EndpointRow(
            name: "remote.upstream.lfsurl",
            remote: "upstream",
            remotes: [
                ("origin", "https://example.com/repo.git"),
                ("upstream", "https://example.com/other.git")
            ],
            config: [("remote.upstream.lfsurl", "https://other.example/lfs")],
            url: "https://other.example/lfs"),
        EndpointRow(
            name: "upload reads lfs.pushurl before lfs.url",
            operation: "upload",
            config: [
                ("lfs.pushurl", "https://push.example/up"),
                ("lfs.url", "https://lfs.example/custom")
            ],
            url: "https://push.example/up"),
        EndpointRow(
            name: "download keeps lfs.url when lfs.pushurl is set",
            config: [
                ("lfs.pushurl", "https://push.example/up"),
                ("lfs.url", "https://lfs.example/custom")
            ],
            url: "https://lfs.example/custom"),
        EndpointRow(
            name: "upload reads lfspushurl before lfsurl",
            operation: "upload",
            config: [
                ("remote.origin.lfspushurl", "https://push.example/lfs-up"),
                ("remote.origin.lfsurl", "https://lfs.example/lfs")
            ],
            url: "https://push.example/lfs-up"),
        EndpointRow(
            name: "download reads lfsurl and ignores lfspushurl",
            config: [
                ("remote.origin.lfspushurl", "https://push.example/lfs-up"),
                ("remote.origin.lfsurl", "https://lfs.example/lfs")
            ],
            url: "https://lfs.example/lfs"),
        EndpointRow(
            name: "upload derives from pushurl",
            operation: "upload",
            config: [("remote.origin.pushurl", "https://push.example/repo.git")],
            url: "https://push.example/repo.git/info/lfs"),
        EndpointRow(
            name: "download ignores pushurl",
            config: [("remote.origin.pushurl", "https://push.example/repo.git")],
            url: "https://example.com/repo.git/info/lfs"),
        EndpointRow(
            name: "insteadOf rewrites the remote",
            remotes: [("origin", "https://github.com/org/repo.git")],
            config: [("url.https://lfs.example/.insteadof", "https://github.com/")],
            url: "https://lfs.example/org/repo.git/info/lfs"),
        EndpointRow(
            name: "upload pushInsteadOf stops insteadOf",
            operation: "upload",
            remotes: [("origin", "https://github.com/org/repo.git")],
            config: [
                ("url.https://lfs.example/.insteadof", "https://github.com/"),
                ("url.https://push.example/.pushinsteadof", "https://github.com/")
            ],
            url: "https://push.example/org/repo.git/info/lfs"),
        EndpointRow(
            name: "download still applies insteadOf when pushInsteadOf is set",
            remotes: [("origin", "https://github.com/org/repo.git")],
            config: [
                ("url.https://lfs.example/.insteadof", "https://github.com/"),
                ("url.https://push.example/.pushinsteadof", "https://github.com/")
            ],
            url: "https://lfs.example/org/repo.git/info/lfs"),
        EndpointRow(
            name: "the longest insteadOf prefix wins",
            remotes: [("origin", "https://github.com/org/repo.git")],
            config: [
                ("url.https://short.example/.insteadof", "https://github.com/"),
                ("url.https://long.example/.insteadof", "https://github.com/org/")
            ],
            url: "https://long.example/repo.git/info/lfs"),
        EndpointRow(
            name: "https nested path keeps a trailing .git",
            remotes: [("origin", "https://example.com/a/b/c.git")],
            url: "https://example.com/a/b/c.git/info/lfs"),
        EndpointRow(
            name: "https without .git gains one",
            remotes: [("origin", "https://example.com/a/b")],
            url: "https://example.com/a/b.git/info/lfs"),
        EndpointRow(
            name: "https keeps its port",
            remotes: [("origin", "https://example.com:8443/a/b.git")],
            url: "https://example.com:8443/a/b.git/info/lfs"),
        EndpointRow(
            name: "one trailing slash is stripped before .git is detected",
            remotes: [("origin", "https://example.com/a/b.git/")],
            url: "https://example.com/a/b.git/info/lfs"),
        EndpointRow(
            name: "a host with no path is extended like path.Ext",
            remotes: [("origin", "https://example.com")],
            url: "https://example.com.git/info/lfs"),
        EndpointRow(
            name: "ssh:// keeps the port off the HTTPS URL and on the metadata",
            remotes: [("origin", "ssh://git@example.com:9000/foo/bar")],
            url: "https://example.com/foo/bar.git/info/lfs",
            user: "git", host: "example.com", port: "9000",
            path: "/foo/bar", userAndHost: "git@example.com"),
        EndpointRow(
            name: "scp-style git@host:path",
            remotes: [("origin", "git@example.com:foo/bar.git")],
            url: "https://example.com/foo/bar.git/info/lfs",
            user: "git", host: "example.com", port: "",
            path: "foo/bar.git", userAndHost: "git@example.com"),
        EndpointRow(
            name: "bracketed scp port",
            remotes: [("origin", "[git@example.com:2222]:foo/bar.git")],
            url: "https://example.com/foo/bar.git/info/lfs",
            user: "git", host: "example.com", port: "2222",
            path: "foo/bar.git", userAndHost: "git@example.com"),
        EndpointRow(
            name: "file:// is not given /info/lfs",
            remotes: [("origin", "file:///tmp/not-a-repo")],
            url: "file:///tmp/not-a-repo"),
        EndpointRow(
            name: "git config lfs.url overrides .lfsconfig",
            config: [("lfs.url", "https://git.example/from-git")],
            lfsconfig: "[lfs]\n\turl = https://file.example/from-file\n",
            url: "https://git.example/from-git"),
        EndpointRow(
            name: ".lfsconfig lfs.url is used when git config has none",
            lfsconfig: "[lfs]\n\turl = https://file.example/from-file\n",
            url: "https://file.example/from-file"),
        EndpointRow(
            name: ".lfsconfig remote.lfspushurl is ignored",
            operation: "upload",
            lfsconfig: "[remote \"origin\"]\n\tlfspushurl = https://unsafe.example/nope\n",
            url: "https://example.com/repo.git/info/lfs")
    ]

    @Test("config, .lfsconfig and derived URLs")
    func table() async throws {
        try await host.run {
            for row in Self.rows {
                let made = try await LFSFixture.make(
                    host, row.name, remotes: row.remotes, config: row.config, lfsconfig: row.lfsconfig)
                let finder = await LFSEndpointFinder(made.client)
                let endpoint = finder.endpoint(operation: row.operation, remote: row.remote)
                #expect(endpoint.url == row.url, "\(row.name) url")
                #expect(endpoint.operation == row.operation, "\(row.name) operation")
                if let user = row.user {
                    #expect(endpoint.ssh.user == user, "\(row.name) user")
                    #expect(endpoint.ssh.host == row.host, "\(row.name) host")
                    #expect(endpoint.ssh.port == row.port, "\(row.name) port")
                    #expect(endpoint.ssh.path == row.path, "\(row.name) path")
                    #expect(endpoint.ssh.userAndHost == row.userAndHost, "\(row.name) userAndHost")
                }
            }
        }
    }
}
