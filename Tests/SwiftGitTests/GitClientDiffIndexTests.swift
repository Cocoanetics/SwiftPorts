// Integration tests that fork the system `git` via `Process` for parity
// checks. Windows has no `/usr/bin/env`, and the swift-android-action's
// MSVC clang doesn't see a stable `git.exe` path either, so gate the
// whole suite to non-Windows. Apple/Linux still cover the integration
// surface; Windows-side logic is covered by the unit-shape tests in
// `GitCommandTests` and `GitLabTests`.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
@testable import SwiftGit

@Suite("GitClient.diffIndex")
struct GitClientDiffIndexTests {

    @Test("staged and unstaged changes match git diff-index, not an index-to-workdir diff")
    func stagedAndUnstaged() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a-v2\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "a.txt"], in: dir)
        try Data("b-dirty\n".utf8).write(to: dir.appendingPathComponent("b.txt"))

        let client = GitClient(workingDirectory: dir)
        let cached = try await client.diffIndex(ref: "HEAD", cached: true)
        let uncached = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: dir)) == cached)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir)) == uncached)
        #expect(cached.map(\.destinationPath) == ["a.txt"])
        #expect(cached.first?.status == "M")
        #expect(cached.first?.oldOID.count == 40)
        #expect(cached.first?.newOID.count == 40)
        #expect(cached.first?.newOID != String(repeating: "0", count: 40))
        #expect(uncached.map(\.destinationPath) == ["a.txt", "b.txt"])
        let dirty = try #require(uncached.first { $0.destinationPath == "b.txt" })
        #expect(dirty.status == "M")
        #expect(dirty.newOID == String(repeating: "0", count: 40))
        #expect(dirty.sourcePath == "b.txt")
    }

    @Test("a delete is a deletion with a zero new id")
    func delete() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["rm", "b.txt"], in: dir)

        let entries = try await GitClient(workingDirectory: dir)
            .diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: dir)) == entries)
        #expect(entries.count == 1)
        #expect(entries[0].status == "D")
        #expect(entries[0].sourcePath == "b.txt")
        #expect(entries[0].destinationPath == "b.txt")
        #expect(entries[0].newMode == 0)
        #expect(entries[0].newOID == String(repeating: "0", count: 40))
        #expect(entries[0].similarity == nil)
    }

    @Test("an exact rename is one R100 record with both paths")
    func rename() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["mv", "a.txt", "moved.txt"], in: dir)

        let entries = try await GitClient(workingDirectory: dir)
            .diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: dir)) == entries)
        #expect(entries.count == 1)
        #expect(entries[0].status == "R")
        #expect(entries[0].similarity == 100)
        #expect(entries[0].sourcePath == "a.txt")
        #expect(entries[0].destinationPath == "moved.txt")
        #expect(entries[0].oldOID == entries[0].newOID)
        #expect(entries[0].oldOID.count == 40)
    }

    @Test("an added copy of an unchanged file stays an addition")
    func copiesStayOff() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try Data(contentsOf: dir.appendingPathComponent("a.txt"))
        try original.write(to: dir.appendingPathComponent("copy.txt"))
        try runGit(["add", "copy.txt"], in: dir)

        let entries = try await GitClient(workingDirectory: dir)
            .diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: dir)) == entries)
        #expect(entries.map(\.status) == ["A"])
        #expect(entries.map(\.destinationPath) == ["copy.txt"])
        #expect(entries[0].similarity == nil)
    }

    @Test("a staged file replaced by a symlink is one T record")
    func typeChange() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "elsewhere")
        try runGit(["add", "a.txt"], in: dir)

        let client = GitClient(workingDirectory: dir)
        let cached = try await client.diffIndex(ref: "HEAD", cached: true)
        let uncached = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: dir)) == cached)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir)) == uncached)
        #expect(cached.count == 1)
        #expect(cached[0].status == "T")
        #expect(cached[0].oldMode == 0o100644)
        #expect(cached[0].newMode == 0o120000)
        #expect(cached[0].sourcePath == "a.txt")
        #expect(cached[0].destinationPath == "a.txt")
        #expect(cached[0].similarity == nil)
        #expect(cached[0].oldOID != cached[0].newOID)
        #expect(uncached == cached)

        try FileManager.default.removeItem(at: file)
        try Data("back\n".utf8).write(to: file)
        let restored = try await client.diffIndex(ref: "HEAD", cached: false)
        let cachedAfter = try await client.diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir)) == restored)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: dir)) == cachedAfter)
        #expect(restored.map(\.status) == ["M"])
        #expect(restored[0].oldMode == 0o100644)
        #expect(restored[0].newMode == 0o100644)
        #expect(restored[0].newOID == String(repeating: "0", count: 40))
        #expect(cachedAfter.map(\.status) == ["T"])

        try FileManager.default.removeItem(at: file)
        let deleted = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir)) == deleted)
        #expect(deleted.map(\.status) == ["D"])
        #expect(deleted[0].newMode == 0)
    }

    @Test("an unresolved merge compares the tree with the work tree")
    func unmerged() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("c\n".utf8).write(to: dir.appendingPathComponent("c.txt"))
        try runGit(["add", "c.txt"], in: dir)
        try runGit(["commit", "-m", "c"], in: dir)
        try runGit(["checkout", "-b", "side"], in: dir)
        try Data("side-a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("side-c\n".utf8).write(to: dir.appendingPathComponent("c.txt"))
        try Data("side-both\n".utf8).write(to: dir.appendingPathComponent("both.txt"))
        try runGit(["rm", "b.txt"], in: dir)
        try runGit(["add", "a.txt", "c.txt", "both.txt"], in: dir)
        try runGit(["commit", "-m", "side"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("main-a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("main-b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try Data("main-both\n".utf8).write(to: dir.appendingPathComponent("both.txt"))
        try runGit(["rm", "c.txt"], in: dir)
        try runGit(["add", "a.txt", "b.txt", "both.txt"], in: dir)
        try runGit(["commit", "-m", "main"], in: dir)
        _ = try runGit(["merge", "side"], in: dir, allowsFailure: true)

        let client = GitClient(workingDirectory: dir)
        let zeros = String(repeating: "0", count: 40)
        let uncached = try await client.diffIndex(ref: "HEAD", cached: false)
        let cached = try await client.diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir)) == uncached)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: dir)) == cached)
        let content = try #require(uncached.first { $0.destinationPath == "a.txt" })
        #expect(content.status == "M")
        #expect(content.oldMode == 0o100644)
        #expect(content.newMode == 0o100644)
        #expect(content.newOID == zeros)
        #expect(content.oldOID != zeros)
        #expect(uncached.first { $0.destinationPath == "c.txt" }?.status == "A")
        #expect(cached.first { $0.destinationPath == "a.txt" }?.status == "U")
        #expect(cached.first { $0.destinationPath == "c.txt" }?.status == "U")

        try FileManager.default.removeItem(at: dir.appendingPathComponent("b.txt"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("c.txt"))
        let removed = try await client.diffIndex(ref: "HEAD", cached: false)
        let removedCached = try await client.diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir)) == removed)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: dir)) == removedCached)
        #expect(removed.first { $0.destinationPath == "b.txt" }?.status == "D")
        #expect(removed.contains { $0.destinationPath == "c.txt" } == false)
        #expect(removedCached.first { $0.destinationPath == "c.txt" }?.status == "U")

        let link = dir.appendingPathComponent("a.txt")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "elsewhere")
        let typed = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir)) == typed)
        #expect(typed.first { $0.destinationPath == "a.txt" }?.status == "T")
        #expect(typed.first { $0.destinationPath == "a.txt" }?.newMode == 0o120000)
    }

    @Test("unborn HEAD is the empty tree, and a dirty file has a zero new id")
    func unbornHead() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffIndexUnborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["init", "-b", "main"], in: dir)
        try Data("one\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("two\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "a.txt", "b.txt"], in: dir)
        let empty = try emptyTree(in: dir)

        let client = GitClient(workingDirectory: dir)
        let cached = try await client.diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: true, ref: empty, in: dir)) == cached)
        #expect(cached.map(\.status) == ["A", "A"])
        #expect(cached.map(\.oldOID) == [String(repeating: "0", count: 40), String(repeating: "0", count: 40)])
        #expect(cached.map(\.oldMode) == [0, 0])

        try Data("two\ndirty\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        let uncached = try await client.diffIndex(ref: "HEAD", cached: false)
        let cachedAfter = try await client.diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: false, ref: empty, in: dir)) == uncached)
        #expect(try parse(gitDiffIndex(cached: true, ref: empty, in: dir)) == cachedAfter)
        let dirty = try #require(uncached.first { $0.destinationPath == "b.txt" })
        #expect(dirty.status == "A")
        #expect(dirty.newOID == String(repeating: "0", count: 40))
        #expect(cachedAfter.first { $0.destinationPath == "b.txt" }?.newOID != dirty.newOID)
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "a.txt", "b.txt"], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        return dir
    }

    /// `-M` is the 50% rename detection `diffIndex` always applies.
    /// Plain `git diff-index` leaves renames off even when `diff.renames` is true.
    private func gitDiffIndex(cached: Bool, ref: String, in dir: URL) throws -> String {
        var args = ["diff-index", "-M", "--abbrev=40"]
        if cached { args.append("--cached") }
        args.append(ref)
        return try runGit(args, in: dir)
    }

    private func emptyTree(in dir: URL) throws -> String {
        try runGit(["hash-object", "-t", "tree", "-w", "--stdin"], in: dir, input: Data())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parse(_ output: String) throws -> [DiffIndexEntry] {
        try output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let raw = line.hasPrefix(":") ? line.dropFirst() : line[...]
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let head = fields[0].split(separator: " ").map(String.init)
            guard head.count == 5, fields.count >= 2,
                  let oldMode = UInt32(head[0], radix: 8),
                  let newMode = UInt32(head[1], radix: 8)
            else { throw Failure("cannot parse diff-index line: \(line)") }
            let token = head[4]
            guard let status = token.first else { throw Failure("missing status in \(line)") }
            let similarity = token.count > 1 ? Int(token.dropFirst()) : nil
            let source = fields[1]
            let destination = fields.count > 2 ? fields[2] : source
            return DiffIndexEntry(
                oldMode: oldMode, newMode: newMode,
                oldOID: head[2], newOID: head[3],
                status: status, similarity: similarity,
                sourcePath: source, destinationPath: destination)
        }
    }

    @discardableResult
    private func runGit(
        _ args: [String], in dir: URL, input: Data? = nil, allowsFailure: Bool = false
    ) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let input {
            let stdin = Pipe()
            p.standardInput = stdin
            try p.run()
            if !input.isEmpty { stdin.fileHandleForWriting.write(input) }
            try stdin.fileHandleForWriting.close()
        } else {
            try p.run()
        }
        p.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        if p.terminationStatus != 0, !allowsFailure {
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

@Suite("GitClient.diffIndex refresh")
struct GitClientDiffIndexRefreshTests {
    private let zeros = String(repeating: "0", count: 40)
    private let past = Date(timeIntervalSince1970: 1_577_833_200)

    @Test("a stat-only touch is reported until refresh, then it stays gone")
    func statOnlyTouch() async throws {
        let origin = try makeRepo()
        try backdate("a.txt", in: origin)
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)
        let index = clientDir.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: index)
        let blobs = try runGit(["ls-files", "-s"], in: clientDir)

        let first = try await client.diffIndex(ref: "HEAD", cached: false)
        let second = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: oracle)) == first)
        #expect(first == second)
        #expect(first.contains { $0.destinationPath == "a.txt" && $0.status == "M" && $0.newOID == zeros })
        #expect(try Data(contentsOf: index) == indexBefore)

        let cached = try await client.diffIndex(ref: "HEAD", cached: true, refresh: true)
        #expect(cached.isEmpty)
        let still = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(still.contains { $0.destinationPath == "a.txt" })
        #expect(try Data(contentsOf: index) == indexBefore)

        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        #expect(try parse(refreshedDiff(in: oracle)) == refreshed)
        #expect(refreshed.contains { $0.destinationPath == "a.txt" } == false)
        let again = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(again == refreshed)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: clientDir)) == refreshed)
        #expect(try runGit(["ls-files", "-s"], in: clientDir) == blobs)
    }

    @Test("a touch newer than the index is refreshed")
    func laterTouch() async throws {
        let origin = try makeRepo()
        let indexFile = origin.appendingPathComponent(".git/index")
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: indexFile.path)
        let touched = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: touched], ofItemAtPath: origin.appendingPathComponent("a.txt").path)
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)
        let blobs = try runGit(["ls-files", "-s"], in: clientDir)
        let plain = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: oracle)) == plain)
        #expect(plain.contains { $0.destinationPath == "a.txt" && $0.status == "M" && $0.newOID == zeros })
        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        #expect(try parse(refreshedDiff(in: oracle)) == refreshed)
        #expect(refreshed.contains { $0.destinationPath == "a.txt" } == false)
        #expect(try await client.diffIndex(ref: "HEAD", cached: false) == refreshed)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: clientDir)) == refreshed)
        #expect(try runGit(["ls-files", "-s"], in: clientDir) == blobs)
    }

    @Test("a same-size edit stays a zero-id modification when refresh is on")
    func sameSizeEdit() async throws {
        let origin = try makeRepo()
        try Data("x\n".utf8).write(to: origin.appendingPathComponent("a.txt"))
        try backdate("a.txt", in: origin)
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)
        let blobs = try runGit(["ls-files", "-s"], in: clientDir)
        let indexStat = try runGit(["ls-files", "--debug", "--", "a.txt"], in: clientDir)

        let plain = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: oracle)) == plain)
        let dirty = try #require(plain.first { $0.destinationPath == "a.txt" })
        #expect(dirty.status == "M")
        #expect(dirty.newOID == zeros)

        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        #expect(try parse(refreshedDiff(in: oracle)) == refreshed)
        let still = try #require(refreshed.first { $0.destinationPath == "a.txt" })
        #expect(still.status == "M")
        #expect(still.newOID == zeros)
        #expect(try runGit(["ls-files", "-s"], in: clientDir) == blobs)
        // A copied sibling can be stat-dirty and is refreshed. The edited
        // file's own index stat must stay, or the next uncached diff hides it.
        #expect(try runGit(["ls-files", "--debug", "--", "a.txt"], in: clientDir) == indexStat)
        let again = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(again.first { $0.destinationPath == "a.txt" }?.newOID == zeros)
    }

    @Test("refresh keeps a staged change whose work tree matches the index")
    func stagedPlusUnstaged() async throws {
        let origin = try makeRepo()
        try Data("AA\n".utf8).write(to: origin.appendingPathComponent("a.txt"))
        try runGit(["add", "a.txt"], in: origin)
        try backdate("a.txt", in: origin)
        try Data("b-dirty-longer\n".utf8).write(to: origin.appendingPathComponent("b.txt"))
        try backdate("b.txt", in: origin)
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)
        let blobs = try runGit(["ls-files", "-s"], in: clientDir)

        let plain = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: oracle)) == plain)
        #expect(plain.first { $0.destinationPath == "a.txt" }?.newOID == zeros)
        #expect(plain.first { $0.destinationPath == "b.txt" }?.newOID == zeros)

        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        #expect(try parse(refreshedDiff(in: oracle)) == refreshed)
        let staged = try #require(refreshed.first { $0.destinationPath == "a.txt" })
        #expect(staged.status == "M")
        #expect(staged.newOID != zeros)
        let unstaged = try #require(refreshed.first { $0.destinationPath == "b.txt" })
        #expect(unstaged.status == "M")
        #expect(unstaged.newOID == zeros)
        #expect(try runGit(["ls-files", "-s"], in: clientDir) == blobs)
    }

    @Test("refresh drops a stat-only file and still reports a rename")
    func renameAfterRefresh() async throws {
        let origin = try makeRepo()
        try runGit(["mv", "a.txt", "moved.txt"], in: origin)
        try backdate("moved.txt", in: origin)
        try backdate("b.txt", in: origin)
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)

        let plain = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: oracle)) == plain)
        #expect(plain.contains { $0.status == "R" && $0.similarity == 100 && $0.destinationPath == "moved.txt" })
        #expect(plain.contains { $0.destinationPath == "b.txt" && $0.newOID == zeros })

        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        #expect(try parse(refreshedDiff(in: oracle)) == refreshed)
        #expect(refreshed.map(\.status) == ["R"])
        #expect(refreshed[0].sourcePath == "a.txt")
        #expect(refreshed[0].destinationPath == "moved.txt")
        #expect(refreshed[0].oldOID == refreshed[0].newOID)
        #expect(refreshed[0].newOID != zeros)
    }

    @Test("refresh leaves mode and type changes in place")
    func modeAndType() async throws {
        let origin = try makeRepo()
        let file = origin.appendingPathComponent("a.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try backdate("a.txt", in: origin)
        let link = origin.appendingPathComponent("b.txt")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "elsewhere")
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)

        let plain = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: oracle)) == plain)
        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        #expect(try parse(refreshedDiff(in: oracle)) == refreshed)
        #expect(refreshed == plain)
        #expect(refreshed.first { $0.destinationPath == "a.txt" }?.newMode == 0o100755)
        #expect(refreshed.first { $0.destinationPath == "b.txt" }?.status == "T")
        #expect(refreshed.first { $0.destinationPath == "b.txt" }?.newOID == zeros)
    }

    @Test("refresh does not clear an unmerged path")
    func conflictRefresh() async throws {
        let origin = try conflictRepo()
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)
        let plain = try await client.diffIndex(ref: "HEAD", cached: false)
        let cached = try await client.diffIndex(ref: "HEAD", cached: true)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: oracle)) == plain)
        #expect(try parse(gitDiffIndex(cached: true, ref: "HEAD", in: oracle)) == cached)
        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        let cachedAfter = try await client.diffIndex(ref: "HEAD", cached: true, refresh: true)
        #expect(try parse(refreshedDiff(in: oracle)) == refreshed)
        #expect(refreshed.first { $0.destinationPath == "a.txt" }
            == plain.first { $0.destinationPath == "a.txt" })
        #expect(cachedAfter == cached)
        #expect(plain.first { $0.destinationPath == "a.txt" }?.status == "M")
        #expect(plain.first { $0.destinationPath == "a.txt" }?.newOID == zeros)
        #expect(cached.first { $0.destinationPath == "a.txt" }?.status == "U")
    }

    @Test("unborn HEAD refresh fills a clean add and keeps a same-size edit")
    func unbornHeadRefresh() async throws {
        let origin = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffIndexRefreshUnborn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: origin)
        try Data("one\n".utf8).write(to: origin.appendingPathComponent("a.txt"))
        try Data("two\n".utf8).write(to: origin.appendingPathComponent("b.txt"))
        try runGit(["add", "a.txt", "b.txt"], in: origin)
        try backdate("a.txt", in: origin)
        try Data("zzz\n".utf8).write(to: origin.appendingPathComponent("b.txt"))
        try backdate("b.txt", in: origin)
        let empty = try emptyTree(in: origin)
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)

        let plain = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: empty, in: oracle)) == plain)
        #expect(plain.allSatisfy { $0.status == "A" && $0.newOID == zeros })

        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        #expect(try parse(refreshedDiff(ref: empty, in: oracle)) == refreshed)
        let clean = try #require(refreshed.first { $0.destinationPath == "a.txt" })
        let dirty = try #require(refreshed.first { $0.destinationPath == "b.txt" })
        #expect(clean.status == "A")
        #expect(clean.newOID != zeros)
        #expect(dirty.status == "A")
        #expect(dirty.newOID == zeros)
    }

    @Test("a sandbox denial fails refresh and leaves the default diff alone")
    func sandboxDeniesRefresh() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try backdate("a.txt", in: dir)
        let shell = Shell(
            environment: Environment(workingDirectory: dir.path),
            sandbox: sandbox(denying: "a.txt", in: dir))
        let indexBefore = try Data(contentsOf: dir.appendingPathComponent(".git/index"))
        try await shell.withCurrent {
            let client = GitClient(workingDirectory: dir)
            let denial = await #expect(throws: Sandbox.Denial.self) {
                try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
            }
            #expect(denial?.url.lastPathComponent == "a.txt")
            let entries = try await client.diffIndex(ref: "HEAD", cached: false)
            #expect(entries.contains { $0.destinationPath == "a.txt" && $0.newOID == zeros })
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent(".git/index")) == indexBefore)
    }

    private func backdate(_ name: String, in dir: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: past], ofItemAtPath: dir.appendingPathComponent(name).path)
    }

    /// Skip `maintenance.lock`. Git unlinks it while `copyItem` walks the tree.
    private func copyRepo(_ source: URL, to dest: URL? = nil) throws -> URL {
        let dest = dest ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffIndexRefresh-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey]
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys)) {
            if item.lastPathComponent == "maintenance.lock" { continue }
            let target = dest.appendingPathComponent(item.lastPathComponent)
            guard let values = try? item.resourceValues(forKeys: keys) else { continue }
            let directory = values.isDirectory == true && values.isSymbolicLink != true
            if directory { _ = try copyRepo(item, to: target) } else { try fm.copyItem(at: item, to: target) }
        }
        return dest
    }

    private func refreshedDiff(ref: String = "HEAD", in dir: URL) throws -> String {
        _ = try runGit(["update-index", "--refresh"], in: dir, allowsFailure: true)
        return try gitDiffIndex(cached: false, ref: ref, in: dir)
    }

    private func sandbox(denying name: String, in dir: URL) -> Sandbox {
        Sandbox(
            documentsDirectory: dir, downloadsDirectory: dir, libraryDirectory: dir,
            moviesDirectory: dir, musicDirectory: dir, picturesDirectory: dir,
            sharedPublicDirectory: dir, temporaryDirectory: dir, trashDirectory: dir,
            userDirectory: dir, cachesDirectory: dir, homeDirectory: dir,
            authorize: { url in
                if url.lastPathComponent == name {
                    throw Sandbox.Denial(url: url, reason: "refresh may not read \(name)")
                }
            })
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffIndexRefresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try runGit(["add", "a.txt", "b.txt"], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        return dir
    }

    private func conflictRepo() throws -> URL {
        let dir = try makeRepo()
        try runGit(["checkout", "-b", "side"], in: dir)
        try Data("side\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "a.txt"], in: dir)
        try runGit(["commit", "-m", "side"], in: dir)
        try runGit(["checkout", "main"], in: dir)
        try Data("main\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "a.txt"], in: dir)
        try runGit(["commit", "-m", "main"], in: dir)
        _ = try runGit(["merge", "side"], in: dir, allowsFailure: true)
        return dir
    }

    private func gitDiffIndex(cached: Bool, ref: String, in dir: URL) throws -> String {
        var args = ["diff-index", "-M", "--abbrev=40"]
        if cached { args.append("--cached") }
        args.append(ref)
        return try runGit(args, in: dir)
    }

    private func emptyTree(in dir: URL) throws -> String {
        try runGit(["hash-object", "-t", "tree", "-w", "--stdin"], in: dir, input: Data())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parse(_ output: String) throws -> [DiffIndexEntry] {
        try output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let raw = line.hasPrefix(":") ? line.dropFirst() : line[...]
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let head = fields[0].split(separator: " ").map(String.init)
            guard head.count == 5, fields.count >= 2,
                  let oldMode = UInt32(head[0], radix: 8),
                  let newMode = UInt32(head[1], radix: 8)
            else { throw Failure("cannot parse diff-index line: \(line)") }
            let token = head[4]
            guard let status = token.first else { throw Failure("missing status in \(line)") }
            let similarity = token.count > 1 ? Int(token.dropFirst()) : nil
            let source = fields[1]
            let destination = fields.count > 2 ? fields[2] : source
            return DiffIndexEntry(
                oldMode: oldMode, newMode: newMode,
                oldOID: head[2], newOID: head[3],
                status: status, similarity: similarity,
                sourcePath: source, destinationPath: destination)
        }
    }

    @discardableResult
    private func runGit(
        _ args: [String], in dir: URL, input: Data? = nil, allowsFailure: Bool = false
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            if !input.isEmpty { stdin.fileHandleForWriting.write(input) }
            try stdin.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        let outStr = String(decoding: (try? out.fileHandleForReading.readToEnd()) ?? Data(), as: UTF8.self)
        if process.terminationStatus != 0, !allowsFailure {
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
