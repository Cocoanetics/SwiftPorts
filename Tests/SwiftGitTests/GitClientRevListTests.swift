// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface; Windows-side logic is covered by the unit-shape tests in
// `GitCommandTests` and `GitLabTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import SwiftGit

@Suite("GitClient.revList")
struct GitClientRevListTests {

    @Test("a linear history matches git rev-list, including an inverted committer date")
    func linearOrder() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try commit("root", date: "2020-01-01T00:00:00Z", file: "f.txt", body: "1\n", in: dir)
        try commit("parent-new", date: "2020-06-01T00:00:00Z", file: "f.txt", body: "2\n", in: dir)
        try commit("child-old", date: "2020-02-01T00:00:00Z", file: "f.txt", body: "3\n", in: dir)

        let client = GitClient(workingDirectory: dir)
        let listed = try await client.revList(starts: ["HEAD"], excludes: [])
        #expect(try gitRevList(["HEAD"], in: dir) == listed)
        // The tip is older than its parent. A pure date sort would emit the
        // parent first; the revision walk still emits the child first.
        let subjects = try subjects(of: listed, in: dir)
        #expect(subjects == ["child-old", "parent-new", "root"])
        let logged = try await client.log(LogQuery(starts: ["HEAD"])).map(\.sha)
        #expect(logged == listed)
    }

    @Test("two tips with an inverted committer date disagree with log()")
    func invertedDateDisagreesWithLog() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try commit("root", date: "2020-01-01T00:00:00Z", file: "f.txt", body: "1\n", in: dir)
        try commit("parent", date: "2020-06-01T00:00:00Z", file: "f.txt", body: "2\n", in: dir)
        try runGit(["branch", "other"], in: dir)
        try commit("childA", date: "2020-02-01T00:00:00Z", file: "f.txt", body: "3\n", in: dir)
        try runGit(["checkout", "other"], in: dir)
        try commit("childB", date: "2020-03-01T00:00:00Z", file: "g.txt", body: "4\n", in: dir)

        let client = GitClient(workingDirectory: dir)
        let forward = try await client.revList(starts: ["main", "other"], excludes: [])
        let reverse = try await client.revList(starts: ["other", "main"], excludes: [])
        let git = try gitRevList(["main", "other"], in: dir)
        #expect(forward == git)
        #expect(reverse == git)
        let names = try subjects(of: forward, in: dir)
        #expect(names == ["childB", "parent", "childA", "root"])

        let logged = try await client.log(LogQuery(starts: ["main", "other"])).map(\.sha)
        #expect(logged != forward)
        let loggedNames = try subjects(of: logged, in: dir)
        // `log()` keeps every child ahead of the parent. `rev-list` has
        // already queued `parent` (June) by the time it reaches `childA` (February).
        #expect(loggedNames.firstIndex(of: "childA")! < loggedNames.firstIndex(of: "parent")!)
        #expect(names.firstIndex(of: "parent")! < names.firstIndex(of: "childA")!)
    }

    @Test("excludes hide a commit and its ancestors, and a tag peels")
    func excludesAndTag() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try commit("one", date: "2020-01-01T00:00:00Z", file: "f.txt", body: "1\n", in: dir)
        try commit("two", date: "2020-01-02T00:00:00Z", file: "f.txt", body: "2\n", in: dir)
        try commit("three", date: "2020-01-03T00:00:00Z", file: "f.txt", body: "3\n", in: dir)
        try runGit(["tag", "-a", "v1", "-m", "tag"], in: dir)

        let client = GitClient(workingDirectory: dir)
        let range = try await client.revList(starts: ["HEAD"], excludes: ["HEAD~1"])
        #expect(try gitRevList(["HEAD", "^HEAD~1"], in: dir) == range)
        #expect(try subjects(of: range, in: dir) == ["three"])
        let fromTag = try await client.revList(starts: ["v1"], excludes: [])
        #expect(try await client.revList(starts: ["HEAD"], excludes: []) == fromTag)
    }

    @Test("an empty start list is rejected, as git rev-list with no commit is")
    func emptyStartsAreRejected() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try commit("root", date: "2020-01-01T00:00:00Z", file: "f.txt", body: "1\n", in: dir)
        await #expect(throws: Libgit2Error.self) {
            try await GitClient(workingDirectory: dir).revList(starts: [])
        }
    }

    @Test("an unborn HEAD yields no commits")
    func unbornHead() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevListUnborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["init", "-b", "main"], in: dir)
        let ids = try await GitClient(workingDirectory: dir).revList(starts: ["HEAD"], excludes: [])
        #expect(ids.isEmpty)
    }

    private func subjects(of ids: [String], in dir: URL) throws -> [String] {
        try ids.map { id in
            try runGit(["log", "-1", "--format=%s", id], in: dir)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func gitRevList(_ args: [String], in dir: URL) throws -> [String] {
        let output = try runGit(["rev-list", "--abbrev=40"] + args, in: dir)
        return output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private func commit(_ message: String, date: String, file: String, body: String, in dir: URL) throws {
        try Data(body.utf8).write(to: dir.appendingPathComponent(file))
        try runGit(["add", file], in: dir)
        try runGit(["commit", "-m", message], in: dir, environment: [
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_DATE": date
        ])
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevListTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        return dir
    }

    @discardableResult
    private func runGit(
        _ args: [String],
        in dir: URL,
        environment: [String: String] = [:]
    ) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment { env[key] = value }
            p.environment = env
        }
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        if p.terminationStatus != 0 {
            let errStr = String(decoding: (try? err.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
            throw Failure("git \(args.joined(separator: " ")) failed: \(errStr)")
        }
        return outStr
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        init(_ message: String) { self.message = message }
        var description: String { message }
    }
}
#endif
