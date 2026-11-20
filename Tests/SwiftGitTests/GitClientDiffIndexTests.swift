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
    private func runGit(_ args: [String], in dir: URL, input: Data? = nil) throws -> String {
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
