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

@Suite("GitClient.lsTree + cat-file")
struct GitClientTreeAndCatFileTests {

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run(); p.waitUntilExit()
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
        let message: String; init(_ m: String) { self.message = m }
        var description: String { message }
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], in: dir)
        try runGit(["config", "user.email", "t@e.com"], in: dir)
        try runGit(["config", "user.name", "T"], in: dir)
        return dir
    }

    @Test("ls-tree: top-level entries only by default")
    func lsTreeTopLevel() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("sub/b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let entries = try await SwiftGit.GitClient(workingDirectory: dir).lsTree()
        // Expect exactly two top-level entries: a.txt (blob) + sub (tree).
        #expect(entries.count == 2)
        let blob = entries.first { $0.path == "a.txt" }
        let tree = entries.first { $0.path == "sub" }
        #expect(blob?.kind == .blob)
        #expect(blob?.mode == "100644")
        #expect(tree?.kind == .tree)
        #expect(tree?.mode == "040000")
    }

    @Test("ls-tree -r flattens subtree blobs into the result")
    func lsTreeRecursive() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("sub/a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("sub/b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let entries = try await SwiftGit.GitClient(workingDirectory: dir)
            .lsTree(recursive: true)
        let blobPaths = entries.filter { $0.kind == .blob }.map(\.path).sorted()
        #expect(blobPaths == ["sub/a.txt", "sub/b.txt"])
    }

    @Test("treeBlobs returns recursive blob contents with prefix")
    func treeBlobs() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("b\n".utf8).write(to: dir.appendingPathComponent("sub/b.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let blobs = try await SwiftGit.GitClient(workingDirectory: dir)
            .treeBlobs(of: "HEAD", prefix: "snap/")
        let byPath = Dictionary(uniqueKeysWithValues: blobs.map { ($0.path, $0) })
        #expect(byPath["snap/a.txt"].map { String(decoding: $0.bytes, as: UTF8.self) } == "a\n")
        #expect(byPath["snap/sub/b.txt"].map { String(decoding: $0.bytes, as: UTF8.self) } == "b\n")
    }

    @Test("commitTime returns nil for raw tree objects")
    func commitTime() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let client = SwiftGit.GitClient(workingDirectory: dir)
        let commitTime = try await client.commitTime(of: "HEAD")
        #expect(commitTime != nil)

        let tree = try runGit(["rev-parse", "HEAD^{tree}"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let treeTime = try await client.commitTime(of: tree)
        #expect(treeTime == nil)
    }

    @Test("cat-file: blob round-trips its bytes")
    func catFileBlob() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = "hello world\n"
        try Data(payload.utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)
        // Resolve the blob's SHA via real git so we exercise revparse.
        let sha = try runGit(["rev-parse", "HEAD:a.txt"], in: dir)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let client = SwiftGit.GitClient(workingDirectory: dir)
        let data = try await client.catFileBlob(sha)
        #expect(String(decoding: data, as: UTF8.self) == payload)
    }

    @Test("objectMetadata reports kind + size for HEAD commit")
    func objectMetadataCommit() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a\n".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try runGit(["add", "."], in: dir)
        try runGit(["commit", "-m", "init"], in: dir)

        let meta = try await SwiftGit.GitClient(workingDirectory: dir)
            .objectMetadata(of: "HEAD")
        #expect(meta.kind == .commit)
        #expect(meta.size > 0)
        #expect(meta.sha.count == 40)
    }
}
#endif
