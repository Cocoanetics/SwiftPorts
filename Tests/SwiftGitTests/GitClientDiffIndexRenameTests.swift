#if os(macOS) || os(Linux)
import Foundation
import Testing
import ShellKit
@testable import SwiftGit

extension GitClientDiffIndexRefreshTests {
    @Test("rename detection hashes an unpaired dirty destination without storing it")
    func dirtyRenameDestination() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["mv", "a.txt", "new.txt"], in: dir)
        try Data("entirely different worktree contents\n".utf8).write(to: dir.appendingPathComponent("new.txt"))
        let shell = Shell(environment: Environment(workingDirectory: dir.path), sandbox: .rooted(at: dir))
        let indexBefore = try Data(contentsOf: dir.appendingPathComponent(".git/index"))
        try await shell.withCurrent {
            let client = GitClient(workingDirectory: dir)
            for refresh in [false, true] {
                let entries = try await client.diffIndex(cached: false, refresh: refresh)
                let expected = try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir))
                #expect(entries == expected)
                let added = try #require(entries.first { $0.status == "A" })
                #expect(added.newOID != zeros)
                await #expect(throws: Libgit2Error.self) { try await client.catFileBlob(added.newOID) }
                if !refresh {
                    #expect(try Data(contentsOf: dir.appendingPathComponent(".git/index")) == indexBefore)
                }
            }
        }
    }

    @Test("uncached rename detection authorizes its worktree destinations before hashing",
           arguments: [false, true], [false, true])
    func authorizeRenameDestination(stagedDeletion: Bool, dirty: Bool) async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        if stagedDeletion {
            try runGit(["mv", "a.txt", "new.txt"], in: dir)
        } else {
            try FileManager.default.copyItem(at: dir.appendingPathComponent("a.txt"),
                                             to: dir.appendingPathComponent("new.txt"))
            try runGit(["add", "new.txt"], in: dir)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("a.txt"))
        }
        if dirty {
            try Data("entirely different contents\n".utf8).write(to: dir.appendingPathComponent("new.txt"))
        }
        let sandbox = Sandbox(
            documentsDirectory: dir, downloadsDirectory: dir, libraryDirectory: dir,
            moviesDirectory: dir, musicDirectory: dir, picturesDirectory: dir,
            sharedPublicDirectory: dir, temporaryDirectory: dir, trashDirectory: dir,
            userDirectory: dir, cachesDirectory: dir, homeDirectory: dir,
            authorize: { url in
                if url.lastPathComponent == "new.txt" {
                    throw Sandbox.Denial(url: url, reason: "rename destination may not be read")
                }
            })
        let shell = Shell(environment: Environment(workingDirectory: dir.path), sandbox: sandbox)
        let indexBefore = try Data(contentsOf: dir.appendingPathComponent(".git/index"))
        try await shell.withCurrent {
            let client = GitClient(workingDirectory: dir)
            let denial = await #expect(throws: Sandbox.Denial.self) {
                try await client.diffIndex(cached: false)
            }
            #expect(denial?.url.lastPathComponent == "new.txt")
            // Cached comparisons read ODB blobs and do not need the worktree file.
            let cached = try await client.diffIndex(cached: true)
            #expect(!cached.isEmpty)
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent(".git/index")) == indexBefore)
    }

    @Test("diffIndex preserves ASCII byte order and does not split typechanges into renames")
    func byteOrderAndSwappedTypeChanges() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("target".utf8).write(to: dir.appendingPathComponent("target.txt"))
        try Data("regular-content".utf8).write(to: dir.appendingPathComponent("to-link.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("from-link.txt").path, withDestinationPath: "target.txt")
        try runGit(["add", "target.txt", "to-link.txt", "from-link.txt"], in: dir)
        try runGit(["commit", "-m", "types"], in: dir)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("to-link.txt"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("from-link.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("to-link.txt").path, withDestinationPath: "target.txt")
        try Data("regular-content".utf8).write(to: dir.appendingPathComponent("from-link.txt"))
        try Data("upper".utf8).write(to: dir.appendingPathComponent("Z.txt"))
        try Data("lower".utf8).write(to: dir.appendingPathComponent("a-added.txt"))
        try runGit(["add", "to-link.txt", "from-link.txt", "Z.txt", "a-added.txt"], in: dir)

        let client = GitClient(workingDirectory: dir)
        for cached in [true, false] {
            let entries = try await client.diffIndex(cached: cached, refresh: !cached)
            let expected = try parse(gitDiffIndex(cached: cached, ref: "HEAD", in: dir))
            #expect(entries == expected)
            #expect(entries.map(\.destinationPath) == ["Z.txt", "a-added.txt", "from-link.txt", "to-link.txt"])
            #expect(entries.filter { $0.destinationPath.hasSuffix("link.txt") }.map(\.status) == ["T", "T"])
        }
    }
}
#endif
