// `git push` with git-lfs's pre-push hook (issue #234): system `git lfs
// install` writes the hook, the remote is a local bare repository, and
// `lfs.url` is the in-process LFS server.
#if os(macOS) || os(Linux)
import Foundation
import GitLFSTestSupport
import Testing

@Suite("git push with git-lfs's pre-push hook",
       .enabled(if: LFSSamePathOracle.isAvailable, "git-lfs 3.7.1 is not on PATH"))
struct GitCommandPushLFSTests {
    /// A repository with one LFS object committed on `main` and the hook
    /// installed, an empty bare `origin`, and the server as `lfs.url`.
    private struct Fixture {
        let oracle: LFSSamePathOracle
        let server: LFSTestServer
        let work: URL
        let remote: URL
        let oid: String

        static func make() async throws -> Fixture {
            let oracle = try LFSSamePathOracle()
            let server = try await LFSTestServer.start()
            let work = try oracle.repository("work")
            let remote = try oracle.repository("remote.git", bare: true)
            try oracle.git(["config", "lfs.url", server.endpoint.absoluteString], in: work)
            try oracle.git(["remote", "add", "origin", remote.path], in: work)
            try oracle.track(["*.bin"], in: work)
            try oracle.write("a.bin", "large contents\n", in: work)
            try oracle.add([".gitattributes", "a.bin"], in: work)
            try oracle.commit("lfs", in: work)
            let pointer = try oracle.git(["cat-file", "-p", "HEAD:a.bin"], in: work).stdout
            let oid = try #require(pointer.split(separator: "\n")
                .first { $0.hasPrefix("oid sha256:") }?.dropFirst("oid sha256:".count))
            return Fixture(oracle: oracle, server: server, work: work, remote: remote, oid: String(oid))
        }

        var hook: URL { work.appendingPathComponent(".git/hooks/pre-push") }

        /// Runs `body` on a new fixture, then shuts the server down and
        /// removes the repositories.
        static func with(_ body: (Fixture) async throws -> Void) async throws {
            let fixture = try await make()
            do { try await body(fixture) } catch {
                await fixture.server.shutdown()
                fixture.oracle.cleanup()
                throw error
            }
            await fixture.server.shutdown()
            fixture.oracle.cleanup()
        }

        func push(_ arguments: [String] = []) async throws -> LFSSamePathOracle.Output {
            try await oracle.port(["push"] + arguments + ["origin", "main"], in: work)
        }

        /// The bare remote's `main`, or `nil` while it has none.
        func remoteMain() throws -> String? {
            let result = try oracle.run(["rev-parse", "--verify", "-q", "refs/heads/main"], in: remote)
            return result.status == 0 ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }

        func head() throws -> String {
            try oracle.git(["rev-parse", "HEAD"], in: work).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func removeLocalObject() throws {
            let path = ".git/lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)"
            try FileManager.default.removeItem(at: work.appendingPathComponent(path))
        }

        var uploadedNothing: Bool { server.requests().isEmpty && server.bytes(for: oid) == nil }
    }

    @Test func uploadsBeforePushing() async throws {
        try await Fixture.with { fixture in
            let hook = try String(contentsOf: fixture.hook, encoding: .utf8)
            #expect(hook.contains("git lfs pre-push"))
            let result = try await fixture.push()
            #expect(result.status == 0, "\(result.stderr)")
            #expect(fixture.server.bytes(for: fixture.oid) == Data("large contents\n".utf8))
            #expect(try fixture.remoteMain() == fixture.head())
        }
    }

    @Test func noVerifySkipsTheUpload() async throws {
        try await Fixture.with { fixture in
            let result = try await fixture.push(["--no-verify"])
            #expect(result.status == 0, "\(result.stderr)")
            #expect(fixture.uploadedNothing)
            #expect(try fixture.remoteMain() == fixture.head())
        }
    }

    /// git-lfs's words, then git's, as system `git push` running the real
    /// hook prints them; the remote ref stays where it was.
    @Test func missingObjectFailsThePush() async throws {
        try await Fixture.with { fixture in
            try fixture.removeLocalObject()
            let expected = try fixture.oracle.run(["push", "origin", "main"], in: fixture.work)
            #expect(try fixture.remoteMain() == nil)
            let actual = try await fixture.push()
            #expect(actual.status == 1)
            #expect(actual.status == expected.status)
            #expect(actual.stderr == expected.stderr)
            // The same lines; the SDK writes its meter's last line before
            // the failure block rather than after it.
            #expect(Set(actual.stdout.split(separator: "\n")) == Set(expected.stdout.split(separator: "\n")))
            #expect(actual.stdout.contains("Git LFS upload failed:\n  (missing) a.bin (\(fixture.oid))\n"))
            #expect(actual.stderr.hasSuffix("error: failed to push some refs to '\(fixture.remote.path)'\n"))
            #expect(try fixture.remoteMain() == nil)
            #expect(fixture.server.bytes(for: fixture.oid) == nil)
        }
    }

    @Test func allowIncompletePushLetsItThrough() async throws {
        try await Fixture.with { fixture in
            try fixture.removeLocalObject()
            try fixture.oracle.git(["config", "lfs.allowincompletepush", "true"], in: fixture.work)
            let result = try await fixture.push()
            #expect(result.status == 0, "\(result.stderr)")
            #expect(try fixture.remoteMain() == fixture.head())
        }
    }

    /// Not git-lfs's: not run, and nothing uploaded, as without a hook.
    @Test func foreignHookIsIgnored() async throws {
        try await Fixture.with { fixture in
            let marker = fixture.work.appendingPathComponent("hook-ran")
            try "#!/bin/sh\n# git lfs pre-push \"$@\"\ntouch '\(marker.path)'\n"
                .write(to: fixture.hook, atomically: false, encoding: .utf8)
            let result = try await fixture.push()
            #expect(result.status == 0, "\(result.stderr)")
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            #expect(fixture.uploadedNothing)
            #expect(try fixture.remoteMain() == fixture.head())
        }
    }

    /// git runs no hook that isn't executable.
    @Test func nonExecutableHookIsIgnored() async throws {
        try await Fixture.with { fixture in
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.hook.path)
            let result = try await fixture.push()
            #expect(result.status == 0, "\(result.stderr)")
            #expect(fixture.uploadedNothing)
            #expect(try fixture.remoteMain() == fixture.head())
        }
    }
}
#endif
