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

@Suite("GitClient.references")
struct GitClientReferencesTests {

    @Test("listing includes tags, notes, stash and remotes, and omits HEAD")
    func allRefsMatchForEachRef() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["branch", "topic"], in: dir)
        try runGit(["tag", "light"], in: dir)
        try runGit(["tag", "-a", "v1", "-m", "annotated"], in: dir)
        try runGit(["notes", "add", "-m", "a note"], in: dir)
        try runGit(["update-ref", "refs/remotes/origin/main", "HEAD"], in: dir)
        try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: dir)
        try Data("wip\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["stash", "push", "-m", "wip"], in: dir)

        let entries = try await GitClient(workingDirectory: dir).references()
        let git = try forEachRef(in: dir)
        #expect(entries.map(\.name) == git.map(\.name))
        #expect(entries.map(\.targetSHA) == git.map(\.sha))
        #expect(entries.map(\.symbolicTarget) == git.map(\.symbolic))
        #expect(!entries.contains { $0.name == "HEAD" })
        let names = Set(entries.map(\.name))
        #expect(names.contains("refs/heads/main"))
        #expect(names.contains("refs/heads/topic"))
        #expect(names.contains("refs/tags/light"))
        #expect(names.contains("refs/tags/v1"))
        #expect(names.contains("refs/notes/commits"))
        #expect(names.contains("refs/stash"))
        #expect(names.contains("refs/remotes/origin/main"))
        #expect(names.contains("refs/remotes/origin/HEAD"))

        let annotated = try #require(entries.first { $0.name == "refs/tags/v1" })
        let peeled = try runGit(["rev-parse", "v1^{commit}"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(annotated.targetSHA != peeled)
        #expect(annotated.symbolicTarget == nil)
        let originHead = try #require(entries.first { $0.name == "refs/remotes/origin/HEAD" })
        #expect(originHead.symbolicTarget == "refs/remotes/origin/main")
        #expect(originHead.targetSHA == entries.first { $0.name == "refs/remotes/origin/main" }?.targetSHA)
    }

    @Test("a glob keeps only the refs whose full name matches")
    func matchingPattern() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["tag", "v1"], in: dir)
        try runGit(["tag", "v2"], in: dir)
        try runGit(["branch", "topic"], in: dir)

        let tags = try await GitClient(workingDirectory: dir).references(matching: "refs/tags/*")
        #expect(tags.map(\.name) == ["refs/tags/v1", "refs/tags/v2"])
        #expect(tags.allSatisfy { $0.name.hasPrefix("refs/tags/") })
    }

    private struct GitRef {
        var sha: String
        var name: String
        var symbolic: String?
    }

    private func forEachRef(in dir: URL) throws -> [GitRef] {
        let output = try runGit(
            ["for-each-ref", "--format=%(objectname) %(refname)%(if)%(symref)%(then) %(symref)%(end)"],
            in: dir)
        return output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return GitRef(sha: fields[0], name: fields[1], symbolic: fields.count > 2 ? fields[2] : nil)
        }
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferencesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "a.txt"], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        return dir
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
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
