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

@Suite("GitClient.merge")
struct GitClientMergeTests {

    /// Build a repo with two divergent branches: `main` ahead by one
    /// commit (trunk.txt), `feature` ahead by another (feat.txt). Both
    /// rooted at the same initial commit.
    private func makeDivergentRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("base\n".utf8).write(to: dir.appendingPathComponent("base.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("feat.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "feat"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("trunk\n".utf8).write(to: dir.appendingPathComponent("trunk.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "trunk"], in: dir)
        return dir
    }

    /// Linear repo: `feature` is one commit ahead of `main` from the
    /// same root. Used for fast-forward tests.
    private func makeLinearRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("base\n".utf8).write(to: dir.appendingPathComponent("base.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("feat\n".utf8).write(to: dir.appendingPathComponent("feat.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "feat"], in: dir)
        try runGit(["checkout", "main"], in: dir)
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

    @Test("fast-forward when ahead is achievable")
    func fastForward() async throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try await GitClient(workingDirectory: dir)
            .merge(ref: "feature")
        guard case let .fastForward(_, _, summary, added, _) = outcome else {
            Issue.record("expected fast-forward, got \(outcome)"); return
        }
        #expect(summary.contains("1 file changed"))
        #expect(added.contains(where: { $0.contains("create mode") && $0.contains("feat.txt") }))
        // After FF, the branch ref should match feature.
        let mainSHA = try runGit(["rev-parse", "main"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let featureSHA = try runGit(["rev-parse", "feature"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(mainSHA == featureSHA)
    }

    @Test("alreadyUpToDate when target is already merged")
    func alreadyUpToDate() async throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = GitClient(workingDirectory: dir)
        _ = try await client.merge(ref: "feature") // brings main up
        let again = try await client.merge(ref: "feature")
        guard case .alreadyUpToDate = again else {
            Issue.record("expected alreadyUpToDate, got \(again)"); return
        }
    }

    @Test("--ff-only refuses to merge when branches diverge")
    func ffOnlyRefuses() async throws {
        let dir = try makeDivergentRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: Libgit2Error.self) {
            _ = try await GitClient(workingDirectory: dir)
                .merge(ref: "feature", fastForward: .onlyFastForward)
        }
    }

    @Test("3-way merge produces a merge commit with two parents")
    func threeWayMergeCommit() async throws {
        let dir = try makeDivergentRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = try await GitClient(workingDirectory: dir)
            .merge(ref: "feature",
                   author: GitSignature(name: "T", email: "t@e.com"))
        guard case let .mergeCommit(sha, summary, added, _) = outcome else {
            Issue.record("expected mergeCommit, got \(outcome)"); return
        }
        #expect(sha.count == 40)
        #expect(summary.contains("file changed"))
        #expect(added.contains(where: { $0.contains("feat.txt") }))

        // Verify the commit has two parents via `git rev-list --parents`.
        let parents = try runGit(["rev-list", "--parents", "-n", "1", sha], in: dir)
            .split(separator: " ")
        #expect(parents.count == 3) // commit + 2 parents
    }

    @Test("conflict surfaces conflicted paths and leaves index conflicted")
    func conflictPath() async throws {
        // Build a conflict scenario: both branches modify the same line.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n2\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("1\n2\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "feat"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\n2\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = try await GitClient(workingDirectory: dir)
            .merge(ref: "feature",
                   author: GitSignature(name: "T", email: "t@e.com"))
        guard case let .conflicts(paths) = outcome else {
            Issue.record("expected conflicts, got \(outcome)"); return
        }
        #expect(paths == ["a.txt"])

        // Working tree should now contain conflict markers.
        let body = try String(contentsOf: dir.appendingPathComponent("a.txt"),
                              encoding: .utf8)
        #expect(body.contains("<<<<<<< HEAD"))
        #expect(body.contains(">>>>>>> "))
    }

    @Test("mergeContinue commits staged conflict resolution")
    func mergeContinue() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("1\n2\n3\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        try runGit(["checkout", "-b", "feature"], in: dir)
        try Data("1\n2\nFEAT\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "feat"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("1\n2\nMAIN\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["commit", "-am", "main"], in: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let client = GitClient(workingDirectory: dir)
        guard case .conflicts = try await client.merge(
            ref: "feature",
            author: GitSignature(name: "T", email: "t@e.com"))
        else {
            Issue.record("expected conflict")
            return
        }

        try Data("1\n2\nresolved\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "a.txt"], in: dir)

        let details = try await client.mergeContinue(
            author: GitSignature(name: "T", email: "t@e.com"))
        #expect(details.sha.count == 40)
        #expect(details.filesChanged == 1)

        let parents = try runGit(["rev-list", "--parents", "-n", "1", "HEAD"], in: dir)
            .split(separator: " ")
        #expect(parents.count == 3)
    }

    @Test("unknown ref throws Libgit2Error")
    func unknownRef() async throws {
        let dir = try makeLinearRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: Libgit2Error.self) {
            _ = try await GitClient(workingDirectory: dir)
                .merge(ref: "nopebranch")
        }
    }
}
#endif
