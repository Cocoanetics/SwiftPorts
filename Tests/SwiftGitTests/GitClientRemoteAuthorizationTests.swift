import Foundation
import Testing
import ShellKit
@testable import SwiftGit

/// Issue #122: `git clone` authorizes scp-like remotes by their host, not as host-less URLs.
@Suite struct GitClientRemoteAuthorizationTests {

    @Test func scpLikeRemotesAuthorizeAsSSHURLs() throws {
        let cases: [(remote: String, authorized: String, host: String)] = [
            ("git@github.com:Cocoanetics/SwiftPorts.git", "ssh://git@github.com/Cocoanetics/SwiftPorts.git", "github.com"),
            ("myhost:repo.git", "ssh://myhost/repo.git", "myhost"),
            ("myhost:/srv/git/repo.git", "ssh://myhost/srv/git/repo.git", "myhost"),
            // Bracketed IPv6 hosts — `URL(string:)` percent-encodes these,
            // and the address's own colons mustn't end the host.
            ("git@[::1]:repo.git", "ssh://git@[::1]/repo.git", "::1"),
            ("[::1]:repo.git", "ssh://[::1]/repo.git", "::1"),
            ("git@[fe80::1%en0]:repo.git", "ssh://git@[fe80::1%25en0]/repo.git", "fe80::1%en0"),
        ]
        for testCase in cases {
            let remote = try #require(URL(string: testCase.remote))
            let url = GitClient.authorizationURL(forRemote: remote)
            #expect(url.absoluteString == testCase.authorized)
            #expect(url.host == testCase.host)
        }
    }

    @Test func urlsAndLocalPathsPassThrough() throws {
        for remote in [
            "https://github.com/Cocoanetics/SwiftPorts.git",
            "ssh://git@github.com/Cocoanetics/SwiftPorts.git",
            "file:///srv/git/repo.git",
            "relative/path/repo.git",
        ] {
            let url = try #require(URL(string: remote))
            #expect(GitClient.authorizationURL(forRemote: url) == url)
        }
        let local = URL(fileURLWithPath: "/srv/git/repo.git")
        #expect(GitClient.authorizationURL(forRemote: local) == local)
    }

    /// The gate now names the host — instead of "non-file URL has no host to authorize", which no
    /// host allowlist could ever pass.
    @Test func cloneOfScpLikeRemoteIsJudgedByHost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientRemoteAuthorizationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = Shell(environment: Environment(), sandbox: Sandbox.rooted(at: root))

        let denial = await #expect(throws: Sandbox.Denial.self) {
            try await shell.withCurrent {
                try await GitClient(workingDirectory: root).clone(
                    url: try #require(URL(string: "git@example.invalid:owner/repo.git")),
                    directory: root.appendingPathComponent("repo"))
            }
        }
        #expect(denial?.reason == "host 'example.invalid' is not in the sandbox allowlist")
    }

    /// A configured remote is judged like a typed one, by where libgit2
    /// connects: its URL after `insteadOf`, a push's push URL, a path as
    /// the process reads it. Before, only typed remotes were gated.
    @Test func configuredRemotesAreJudgedByWhereTheyConnect() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientRemoteAuthorizationTests-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientRemoteAuthorizationTests-outside-\(UUID().uuidString)")
        defer { [root, outside].forEach { try? FileManager.default.removeItem(at: $0) } }
        let repo = root.appendingPathComponent("repo")
        try Repository.initialize(at: repo, initialBranch: "main")
        let inside = root.appendingPathComponent("inside.git")
        try Repository.initialize(at: inside, bare: true, initialBranch: "main")
        try Repository.initialize(at: outside, bare: true, initialBranch: "main")
        let shell = Shell(environment: Environment(workingDirectory: repo.path), sandbox: Sandbox.rooted(at: root))

        try await shell.withCurrent {
            let client = GitClient(workingDirectory: repo)
            try await client.addRemote(name: "web", remote: "https://example.invalid/owner/repo.git")
            try await client.addRemote(name: "mirror", remote: inside.path)
            try await client.configSet("remote.mirror.pushurl", "https://example.invalid/mirror.git")
            try await client.addRemote(name: "short", remote: "short:repo.git")
            try await client.configSet("url.https://example.invalid/.insteadOf", "short:")
            try await client.addRemote(name: "outside", remote: outside.path)

            func denial(_ body: () async throws -> Void) async -> Sandbox.Denial? {
                do { try await body() } catch let denial as Sandbox.Denial { return denial } catch {}
                return nil
            }
            let hostDenied = "host 'example.invalid' is not in the sandbox allowlist"
            #expect(await denial { try await client.fetch(remote: "web", refspecs: [], depth: nil) }?.reason
                    == hostDenied)
            #expect(await denial { try await client.fetch(remote: "short", refspecs: [], depth: nil) }?.reason
                    == hostDenied)
            // The mirror fetches from inside the sandbox, but pushes out.
            #expect(await denial { try await client.fetch(remote: "mirror", refspecs: [], depth: nil) } == nil)
            #expect(await denial {
                try await client.push(remote: "mirror", refspecs: ["HEAD:refs/heads/x"], setUpstream: false)
            }?.reason == hostDenied)
            #expect(await denial { try await client.fetch(remote: "outside", refspecs: [], depth: nil) } != nil)

            // A scheme no transport handles is refused, as git refuses
            // it, rather than taken for SSH.
            try await client.addRemote(name: "weird", remote: "foo://example.invalid/r.git")
            await #expect(throws: UnsupportedTransportError.noHelper(scheme: "foo")) {
                try await client.fetch(remote: "weird", refspecs: [], depth: nil)
            }

            // A typed remote is judged after libgit2's insteadOf too: a
            // scp-style `short:` and a path inside the sandbox both lead
            // out to the blocked host.
            #expect(await denial { try await client.fetch(remote: "short:repo.git", refspecs: [], depth: nil) }?
                .reason == hostDenied)
            try await client.configSet("url.https://example.invalid/.insteadOf", inside.path)
            #expect(await denial { try await client.fetch(remote: inside.path, refspecs: [], depth: nil) }?
                .reason == hostDenied)
            // git rewrites a relative path as typed, before reading it as one.
            try await client.configSet("url.https://example.invalid/alias/.insteadOf", "../alias")
            #expect(await denial { try await client.fetch(remote: "../alias", refspecs: [], depth: nil) }?
                .reason == hostDenied)
        }
    }

    /// git opens a configured relative remote from the top of the work
    /// tree, and so does libgit2 now: the gate authorizes that location,
    /// the one GitKit connects to, never the path as read from the
    /// shell's directory or the process's.
    @Test func configuredRelativeRemotesAreJudgedFromTheTopOfTheWorkTree() async throws {
        // As the kernel spells it (`/private/var`, on macOS), as libgit2
        // reports the top of the work tree.
        func onDisk(_ path: String) -> String? {
            realpath(path, nil).map { defer { free($0) }; return String(cString: $0) }
        }
        let base = URL(fileURLWithPath: try #require(onDisk(FileManager.default.temporaryDirectory.path)))
        let root = base.appendingPathComponent("GitClientRemoteAuthorizationTests-\(UUID().uuidString)")
        let name = "relative-\(UUID().uuidString).git"
        // `../../<name>` from `repo/sub` is inside the sandbox; from the
        // top of the work tree, where git reads it, it's outside.
        let inside = root.appendingPathComponent(name), outside = base.appendingPathComponent(name)
        defer { [root, outside].forEach { try? FileManager.default.removeItem(at: $0) } }
        let repo = root.appendingPathComponent("repo"), sub = repo.appendingPathComponent("sub")
        try Repository.initialize(at: repo, initialBranch: "main")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Repository.initialize(at: inside, bare: true, initialBranch: "main")
        try Repository.initialize(at: outside, bare: true, initialBranch: "main")
        let shell = Shell(environment: Environment(workingDirectory: sub.path), sandbox: Sandbox.rooted(at: root))

        try await shell.withCurrent {
            let client = GitClient(workingDirectory: sub)
            try await client.addRemote(name: "escape", remote: "../../\(name)")
            try await client.addRemote(name: "sibling", remote: "../\(name)")
            try await client.configSet("remote.split.url", "../\(name)")
            try await client.configSet("remote.split.pushurl", "../../\(name)")

            await #expect(throws: Sandbox.Denial.self) {
                try await client.fetch(remote: "escape", refspecs: [], depth: nil)
            }
            await #expect(throws: Sandbox.Denial.self) {
                _ = try await client.resolveRemoteOperand("escape")
            }
            await #expect(throws: Sandbox.Denial.self) {
                _ = try await client.resolveRemoteOperand("split", for: .push)
            }
            // What's authorized is the exact string GitKit connects to: the
            // path joined to the top, `..` and all, which the gate and the
            // kernel both resolve on disk, symlinks included.
            let fromTop = repo.path + "/../\(name)"
            let sibling = try await client.resolveRemoteOperand("sibling")
            #expect(sibling == .init(remote: "sibling", location: fromTop))
            let split = try await client.resolveRemoteOperand("split")
            #expect(split == .init(remote: "split", location: fromTop))
            #expect(onDisk(fromTop) == inside.path)
            try await client.fetch(remote: "sibling", refspecs: [], depth: nil)
            // A typed path is read from the top the same way, and keeps
            // its spelling for GitKit to show.
            let typed = try await client.resolveRemoteOperand("../\(name)")
            #expect(typed == .init(remote: "../\(name)", location: fromTop))
            await #expect(throws: Sandbox.Denial.self) {
                _ = try await client.resolveRemoteOperand("../../\(name)")
            }
        }
    }

    @Test func cloneOfBracketedIPv6RemoteIsJudgedByHost() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientRemoteAuthorizationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shell = Shell(environment: Environment(), sandbox: Sandbox.rooted(at: root))

        let denial = await #expect(throws: Sandbox.Denial.self) {
            try await shell.withCurrent {
                try await GitClient(workingDirectory: root).clone(
                    url: try #require(URL(string: "git@[::1]:repo.git")),
                    directory: root.appendingPathComponent("repo"))
            }
        }
        #expect(denial?.reason == "host '::1' is not in the sandbox allowlist")
    }
}
