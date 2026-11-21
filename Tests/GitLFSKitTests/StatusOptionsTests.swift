import Foundation
import Testing
import Crypto
import ShellKit
import SwiftGit
@testable import GitLFSKit

@Suite("StatusOptions")
struct StatusOptionsTests {
    private static let zero = String(repeating: "0", count: 40)

    private func withRepo(
        _ body: (IsolatedLFSHost, URL, GitClient) async throws -> Void
    ) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let (dir, client) = try await LFSFixture.make(host, "status")
            try await body(host, dir, client)
        }
    }

    private func scan(_ client: GitClient, _ dir: URL) async throws -> StatusIndex {
        try await StatusOptions().scanIndex(client: client, repositoryRoot: dir)
    }

    /// Media bytes beyond one 64 KiB read, and the pointer text naming them.
    private func media(_ seed: UInt8, count: Int = 3 * 64 * 1024 + 17) -> (bytes: Data, pointer: Data) {
        let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0) ^ seed })
        let oid = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (bytes, Data(Pointer(oid: oid, size: Int64(count)).encoded.utf8))
    }

    private func write(_ data: Data, _ name: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func stage(_ data: Data, _ name: String, in dir: URL, client: GitClient) async throws -> String {
        try write(data, name, in: dir)
        try await client.add(paths: [name])
        return try #require(try await client.indexedEntries().first { $0.path == name }).oid
    }

    private func commit(_ client: GitClient) async throws {
        _ = try await client.commit(message: "commit", author: nil, allowEmpty: false)
    }

    private func entry(
        _ status: Character, _ old: String, _ new: String, _ path: String,
        oldMode: UInt32 = 0o100644, newMode: UInt32 = 0o100644, from source: String? = nil,
        similarity: Int? = nil
    ) -> DiffIndexEntry {
        DiffIndexEntry(oldMode: oldMode, newMode: newMode, oldOID: old, newOID: new,
                       status: status, similarity: similarity,
                       sourcePath: source ?? path, destinationPath: path)
    }

    @Test("HEAD pointer A, index pointer B and B's media keep only the cached change")
    func stagedPointerWithSmudgedWorktree() async throws {
        try await withRepo { _, dir, client in
            let first = media(1)
            let second = media(2)
            let pointerA = try await stage(first.pointer, "a.bin", in: dir, client: client)
            try await commit(client)
            let pointerB = try await stage(second.pointer, "a.bin", in: dir, client: client)
            try write(second.bytes, "a.bin", in: dir)
            let staged = [entry("M", pointerA, pointerB, "a.bin")]
            #expect(try await scan(client, dir) == StatusIndex(staged: staged, unstaged: []))

            // Different media of the same size is a real work-tree change.
            try write(media(3, count: second.bytes.count).bytes, "a.bin", in: dir)
            #expect(try await scan(client, dir) == StatusIndex(
                staged: staged, unstaged: [entry("M", pointerA, Self.zero, "a.bin")]))
            try write(media(3).bytes + Data([0]), "a.bin", in: dir)
            #expect(try await scan(client, dir) == StatusIndex(
                staged: staged, unstaged: [entry("M", pointerA, Self.zero, "a.bin")]))
        }
    }

    @Test("smudged and pointer-only files at HEAD are clean")
    func cleanPointerFiles() async throws {
        try await withRepo { _, dir, client in
            let smudged = media(4)
            let pointerOnly = media(5)
            _ = try await stage(smudged.pointer, "smudged.bin", in: dir, client: client)
            _ = try await stage(pointerOnly.pointer, "nested/pointer.bin", in: dir, client: client)
            try await commit(client)
            try write(smudged.bytes, "smudged.bin", in: dir)
            #expect(try await scan(client, dir) == StatusIndex(staged: [], unstaged: []))
        }
    }

    @Test("ordinary tracked files keep staged and unstaged records")
    func ordinaryTrackedEntries() async throws {
        try await withRepo { _, dir, client in
            let old = try await stage(Data("one\n".utf8), "plain.txt", in: dir, client: client)
            try await commit(client)
            let new = try await stage(Data("two\n".utf8), "plain.txt", in: dir, client: client)
            let added = try await stage(Data("new\n".utf8), "added.txt", in: dir, client: client)
            try write(Data("three\n".utf8), "plain.txt", in: dir)
            // The clean addition is reported by both diffs and listed once, as staged.
            #expect(try await scan(client, dir) == StatusIndex(
                staged: [entry("A", Self.zero, added, "added.txt", oldMode: 0),
                         entry("M", old, new, "plain.txt")],
                unstaged: [entry("M", old, Self.zero, "plain.txt")]))
        }
    }

    @Test("a clean indexed addition with a missing blob remains renderable")
    func missingCleanAddition() async throws {
        try await withRepo { _, dir, client in
            let oid = try await stage(Data("ordinary file".utf8), "x.dat", in: dir, client: client)
            let object = dir.appendingPathComponent(".git/objects/\(oid.prefix(2))/\(oid.dropFirst(2))")
            try FileManager.default.removeItem(at: object)
            #expect(try await scan(client, dir) == StatusIndex(
                staged: [entry("A", Self.zero, oid, "x.dat", oldMode: 0)], unstaged: []))
            var options = StatusOptions()
            let human = try await options.status(client: client)
            #expect(human.status == 0 && human.stderr.isEmpty && human.stdout.contains("(?: <missing>)"))
            options.porcelain = true
            let porcelain = try await options.status(client: client)
            #expect(porcelain.status == 0 && porcelain.stderr.isEmpty && porcelain.stdout == "A  x.dat\n")
        }
    }

    @Test("staged pointer additions with smudged bytes are only staged")
    func stagedAdditions() async throws {
        try await withRepo { _, dir, client in
            _ = try await stage(Data("hi\n".utf8), "README.md", in: dir, client: client)
            try await commit(client)
            let added = media(6)
            let changed = media(7)
            let addedOID = try await stage(added.pointer, "added.bin", in: dir, client: client)
            let changedOID = try await stage(changed.pointer, "changed.bin", in: dir, client: client)
            try write(added.bytes, "added.bin", in: dir)
            try write(media(8).bytes, "changed.bin", in: dir)
            #expect(try await scan(client, dir) == StatusIndex(
                staged: [entry("A", Self.zero, addedOID, "added.bin", oldMode: 0),
                         entry("A", Self.zero, changedOID, "changed.bin", oldMode: 0)],
                unstaged: [entry("A", Self.zero, Self.zero, "changed.bin", oldMode: 0)]))
        }
    }

    @Test("an unborn HEAD is the empty tree")
    func unbornHead() async throws {
        try await withRepo { _, dir, client in
            let file = media(9)
            let oid = try await stage(file.pointer, "a.bin", in: dir, client: client)
            try write(file.bytes, "a.bin", in: dir)
            #expect(try await scan(client, dir) == StatusIndex(
                staged: [entry("A", Self.zero, oid, "a.bin", oldMode: 0)], unstaged: []))
        }
    }

    @Test("a renamed smudged pointer pairs again and dedupes against the staged rename")
    func renamedPointer() async throws {
        try await withRepo { _, dir, client in
            let file = media(10)
            let oid = try await stage(file.pointer, "old.bin", in: dir, client: client)
            try await commit(client)
            try await client.move(from: "old.bin", to: "new.bin")
            try write(file.bytes, "new.bin", in: dir)
            #expect(try await scan(client, dir) == StatusIndex(
                staged: [entry("R", oid, oid, "new.bin", from: "old.bin", similarity: 100)],
                unstaged: []))
        }
    }

    /// Pointers sharing extension lines stay above 50% similar across targets.
    private func extendedPointer(_ file: (bytes: Data, pointer: Data)) throws -> Data {
        let extensions = (0..<6).map {
            PointerExtension(name: "ext\($0)", priority: $0, oid: String(repeating: "\($0)", count: 64))
        }
        let plain = try Pointer.decode(file.pointer)
        return Data(Pointer(oid: plain.oid, size: plain.size, extensions: extensions).encoded.utf8)
    }

    @Test("a renamed pointer with a new target pairs by similarity, as the staged rename does")
    func renamedChangedPointer() async throws {
        try await withRepo { _, dir, client in
            let second = media(18)
            let oldOID = try await stage(try extendedPointer(media(17)), "old.bin", in: dir, client: client)
            try await commit(client)
            try await client.move(from: "old.bin", to: "new.bin")
            let newOID = try await stage(try extendedPointer(second), "new.bin", in: dir, client: client)
            let cached = try await client.diffIndex(cached: true)
            let similarity = try #require(cached.first?.similarity)
            #expect(cached == [entry("R", oldOID, newOID, "new.bin", from: "old.bin", similarity: similarity)])
            #expect(similarity < 100)

            try write(second.bytes, "new.bin", in: dir)
            #expect(try await scan(client, dir) == StatusIndex(staged: cached, unstaged: []))
            try write(media(19).bytes, "new.bin", in: dir)
            #expect(try await scan(client, dir).unstaged.map(\.status) == ["A", "D"])
        }
    }

    @Test("an unstaged deletion pairs with a corrected, similar staged addition")
    func unstagedDeletionPairsBySimilarity() async throws {
        try await withRepo { _, dir, client in
            let second = media(21)
            let oldOID = try await stage(try extendedPointer(media(20)), "old.bin", in: dir, client: client)
            try await commit(client)
            let newOID = try await stage(try extendedPointer(second), "new.bin", in: dir, client: client)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("old.bin"))
            try write(second.bytes, "new.bin", in: dir)
            let status = try await scan(client, dir)
            #expect(status.staged == [entry("A", Self.zero, newOID, "new.bin", oldMode: 0)])
            let rename = try #require(status.unstaged.first)
            #expect(status.unstaged == [entry("R", oldOID, newOID, "new.bin", from: "old.bin",
                                              similarity: rename.similarity)])
            #expect((50..<100).contains(rename.similarity ?? 0))

            // The same score git gives the pair once old.bin's deletion is staged.
            try await client.remove(paths: ["old.bin"], keepWorktree: true)
            #expect(try await client.diffIndex(cached: true).first?.similarity == rename.similarity)
        }
    }

    #if !os(Windows)
    @Test("mode and type changes are kept")
    func modeAndTypeChanges() async throws {
        try await withRepo { _, dir, client in
            let executable = media(11)
            let linked = media(12)
            let executableOID = try await stage(executable.pointer, "exec.bin", in: dir, client: client)
            let linkedOID = try await stage(linked.pointer, "link.bin", in: dir, client: client)
            try await commit(client)
            try write(executable.bytes, "exec.bin", in: dir)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("exec.bin").path)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("link.bin"))
            try write(linked.bytes, "target", in: dir)
            try FileManager.default.createSymbolicLink(
                atPath: dir.appendingPathComponent("link.bin").path, withDestinationPath: "target")
            #expect(try await scan(client, dir) == StatusIndex(staged: [], unstaged: [
                entry("M", executableOID, Self.zero, "exec.bin", newMode: 0o100755),
                entry("T", linkedOID, Self.zero, "link.bin", newMode: 0o120000)]))
        }
    }

    @Test("a staged symlink-to-pointer replacement with matching media is only staged")
    func stagedSymlinkReplacement() async throws {
        try await withRepo { _, dir, client in
            let file = media(22)
            try write(Data("x".utf8), "target", in: dir)
            try FileManager.default.createSymbolicLink(
                atPath: dir.appendingPathComponent("a.bin").path, withDestinationPath: "target")
            try await client.add(paths: ["target", "a.bin"])
            try await commit(client)
            let link = try #require(try await client.indexedEntries().first { $0.path == "a.bin" }).oid
            try FileManager.default.removeItem(at: dir.appendingPathComponent("a.bin"))
            let pointer = try await stage(file.pointer, "a.bin", in: dir, client: client)
            try write(file.bytes, "a.bin", in: dir)
            let staged = [entry("T", link, pointer, "a.bin", oldMode: 0o120000)]
            #expect(try await scan(client, dir) == StatusIndex(staged: staged, unstaged: []))
            try write(media(23).bytes, "a.bin", in: dir)
            #expect(try await scan(client, dir) == StatusIndex(
                staged: staged, unstaged: [entry("T", link, Self.zero, "a.bin", oldMode: 0o120000)]))
        }
    }
    #endif

    @Test("a conflicted pointer is never compared against a conflict stage")
    func conflicts() async throws {
        try await withRepo { _, dir, client in
            let base = media(13)
            let ours = media(14)
            let theirs = media(15)
            _ = try await stage(base.pointer, "a.bin", in: dir, client: client)
            try await commit(client)
            try await client.checkoutNewBranch(name: "side")
            _ = try await stage(theirs.pointer, "a.bin", in: dir, client: client)
            try await commit(client)
            try await client.checkout(ref: "main")
            let oursOID = try await stage(ours.pointer, "a.bin", in: dir, client: client)
            try await commit(client)
            _ = try? await client.merge(ref: "side")
            let stages = try await client.indexedEntries().filter { $0.path == "a.bin" }.map(\.stage)
            #expect(stages.sorted() == [1, 2, 3])
            // The "ours" media matches stage 2's pointer target, yet stays a change.
            try write(ours.bytes, "a.bin", in: dir)
            let uncached = try await client.diffIndex(cached: false, refresh: true)
            #expect(uncached == [entry("M", oursOID, Self.zero, "a.bin")])
            #expect(try await StatusOptions().comparePointers(
                uncached, client: client, repositoryRoot: dir) == uncached)
            // The cached U shares the work-tree record's key, as in upstream.
            let status = try await scan(client, dir)
            #expect(status.staged.map(\.status) == ["U"])
            #expect(status.staged.first?.oldOID == oursOID)
            #expect(status.unstaged == [])
        }
    }

    @Test("authorization and object errors propagate")
    func errorsPropagate() async throws {
        try await withRepo { host, dir, client in
            let file = media(16)
            _ = try await stage(file.pointer, "blocked.bin", in: dir, client: client)
            try await commit(client)
            try write(file.bytes, "blocked.bin", in: dir)
            let shell = Shell(environment: Environment(variables: host.variables, workingDirectory: host.root.path))
            shell.sandbox = host.sandbox(refusing: { $0.lastPathComponent == "blocked.bin" })
            _ = await shell.withCurrent {
                await #expect(throws: Sandbox.Denial.self) { try await scan(client, dir) }
            }
            await #expect(throws: (any Error).self) {
                try await StatusOptions().scanIndex("no-such-ref", client: client, repositoryRoot: dir)
            }
        }
    }
}
