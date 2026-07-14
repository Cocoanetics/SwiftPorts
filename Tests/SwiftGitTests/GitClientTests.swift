// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface; Windows-side logic is covered by the unit-shape tests in
// `GitCommandTests` and `GitLabTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ForgeKit
@testable import SwiftGit

@Suite("GitClient")
struct GitClientTests {

    // Local-only round-trip — no network. We init a repo with the
    // command-line `git` binary (so we don't depend on libgit2's init
    // path in the test), then exercise the libgit2-backed reads.
    private func makeFixtureRepo(withCommit: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "test@example.com"], in: dir)
        try runGit(["config", "user.name", "Test"], in: dir)

        if withCommit {
            let readme = dir.appendingPathComponent("README.md")
            try Data("hi\n".utf8).write(to: readme)
            try runGit(["add", "README.md"], in: dir)
            try runGit(["commit", "-m", "init"], in: dir)
        }
        return dir
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(),
                            as: UTF8.self)
        if p.terminationStatus != 0 {
            let errStr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(),
                                as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(errStr)")
        }
        return outStr
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ m: String) { self.message = m }
        var description: String { message }
    }

    @Test("currentBranch reports the HEAD shorthand")
    func currentBranch() async throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = GitClient(workingDirectory: dir)
        let branch = try await client.currentBranch()
        #expect(branch == "main")
    }

    @Test("currentBranch returns nil when HEAD is unborn")
    func currentBranchUnborn() async throws {
        let dir = try makeFixtureRepo(withCommit: false)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = GitClient(workingDirectory: dir)
        let branch = try await client.currentBranch()
        #expect(branch == nil)
    }

    @Test("addRemote then remoteURL round-trips a URL")
    func addAndReadRemote() async throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = GitClient(workingDirectory: dir)
        let url = URL(string: "https://github.com/example/repo.git")!
        try await client.addRemote(name: "origin", url: url)

        let read = try await client.remoteURL(named: "origin")
        #expect(read?.absoluteString == url.absoluteString)
    }

    @Test("remoteURL returns nil for a missing remote")
    func remoteURLMissing() async throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = GitClient(workingDirectory: dir)
        let read = try await client.remoteURL(named: "origin")
        #expect(read == nil)
    }

    @Test("upstreamBranch returns the abbreviated upstream ref")
    func upstreamBranch() async throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Configure a fake upstream — no fetch / push, just config writes.
        // `git_branch_upstream_name` needs the remote to exist so it can
        // resolve the upstream against the fetch refspec.
        try runGit(["remote", "add", "origin", "https://example.invalid/repo.git"], in: dir)
        try runGit(["config", "branch.main.remote", "origin"], in: dir)
        try runGit(["config", "branch.main.merge", "refs/heads/main"], in: dir)
        try runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], in: dir)

        let client = GitClient(workingDirectory: dir)
        let upstream = try await client.upstreamBranch(of: "main")
        #expect(upstream == "origin/main")
    }

    @Test("upstreamBranch returns nil when no upstream is set")
    func upstreamBranchNone() async throws {
        let dir = try makeFixtureRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = GitClient(workingDirectory: dir)
        let upstream = try await client.upstreamBranch(of: "main")
        #expect(upstream == nil)
    }

    @Test("fetch prunes stale remote-tracking branches only when requested")
    func fetchPrune() async throws {
        let source = try makeFixtureRepo()
        let clone = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitClientFetchPrune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        defer { try? FileManager.default.removeItem(at: clone) }

        try runGit(["branch", "feature"], in: source)
        try await GitClient(workingDirectory: clone.deletingLastPathComponent())
            .clone(url: source, directory: clone)
        try runGit(["branch", "-D", "feature"], in: source)
        try runGit(["config", "remote.origin.prune", "true"], in: clone)

        let client = GitClient(workingDirectory: clone)
        let refspec = "+refs/heads/*:refs/remotes/origin/*"
        try await client.fetch(remote: "origin", refspec: refspec, depth: nil)

        var refs = try runGit(
            ["for-each-ref", "--format=%(refname)", "refs/remotes"], in: clone)
        #expect(refs.contains("refs/remotes/origin/feature"))

        try await client.fetch(
            remote: "origin", refspec: refspec, depth: nil, prune: true)

        refs = try runGit(
            ["for-each-ref", "--format=%(refname)", "refs/remotes"], in: clone)
        #expect(!refs.contains("refs/remotes/origin/feature"))
    }
}
#endif
