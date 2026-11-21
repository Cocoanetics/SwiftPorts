import Foundation
import Testing
import CGitKit
@testable import SwiftGit
import GitLFSKit

@Suite("GitScanner")
struct GitScannerTests {
    private static let first = Pointer(oid: String(repeating: "a", count: 64), size: 12)
    private static let second = Pointer(oid: String(repeating: "b", count: 64), size: 34)

    private func withRepo(_ body: (URL, GitClient) async throws -> Void) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let (dir, client) = try await LFSFixture.make(host, "scan")
            try await body(dir, client)
        }
    }

    private func write(_ text: String, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    private func commit(_ client: GitClient, _ message: String = "pointers") async throws -> String {
        try await client.add(paths: [])
        return try await client.commit(message: message, author: nil, allowEmpty: false)
    }

    /// Add a gitlink directly to the test index, without a subprocess or
    /// a live submodule checkout.
    private func addGitlink(_ client: GitClient, target: String) async throws {
        try await client.withRepository { repository in
            let repo = try #require(GitClient.handle(of: repository))
            var index: OpaquePointer?
            #expect(git_repository_index(&index, repo) == 0)
            defer { git_index_free(index) }
            var entry = git_index_entry()
            entry.mode = 0o160000
            #expect(git_oid_fromstr(&entry.id, target) == 0)
            "module".withCString { path in
                entry.path = path
                #expect(git_index_add(index, &entry) == 0)
            }
            #expect(git_index_write(index) == 0)
        }
    }

    private func addReference(_ client: GitClient, name: String, target: inout git_oid) async throws {
        try await client.withRepository { repository in
            let repo = try #require(GitClient.handle(of: repository))
            var reference: OpaquePointer?
            #expect(git_reference_create(&reference, repo, name, &target, 0, nil) == 0)
            git_reference_free(reference)
        }
    }

    private func standaloneBlob(_ client: GitClient, pointer: Pointer) async throws -> git_oid {
        try await client.withRepository { repository in
            let repo = try #require(GitClient.handle(of: repository))
            let data = Data(pointer.encoded.utf8)
            var oid = git_oid()
            let rc = data.withUnsafeBytes { bytes in
                git_blob_create_from_buffer(&oid, repo, bytes.baseAddress, bytes.count)
            }
            #expect(rc == 0)
            return oid
        }
    }

    private func standaloneTree(
        _ client: GitClient, blob: inout git_oid, path: String = "nested.dat"
    ) async throws -> git_oid {
        try await client.withRepository { repository in
            let repo = try #require(GitClient.handle(of: repository))
            var builder: OpaquePointer?
            #expect(git_treebuilder_new(&builder, repo, nil) == 0)
            defer { git_treebuilder_free(builder) }
            let inserted = path.withCString {
                git_treebuilder_insert(nil, builder, $0, &blob, GIT_FILEMODE_BLOB)
            }
            #expect(inserted == 0)
            var oid = git_oid()
            #expect(git_treebuilder_write(&oid, builder) == 0)
            return oid
        }
    }

    private func addIndexBlob(
        _ client: GitClient, path: String, blob: inout git_oid
    ) async throws {
        try await client.withRepository { repository in
            let repo = try #require(GitClient.handle(of: repository))
            var index: OpaquePointer?
            #expect(git_repository_index(&index, repo) == 0)
            defer { git_index_free(index) }
            var entry = git_index_entry()
            entry.mode = 0o100644
            entry.id = blob
            let added = path.withCString {
                entry.path = $0
                return git_index_add(index, &entry)
            }
            #expect(added == 0)
            #expect(git_index_write(index) == 0)
        }
    }

    /// A loose pack-style header declaring a blob at the cutoff, with no
    /// payload. Header-only sizing can reject it; any full blob read fails.
    private func truncatedCutoffBlob(in dir: URL) throws -> git_oid {
        let hex = String(repeating: "d", count: 40)
        var oid = git_oid()
        #expect(git_oid_fromstr(&oid, hex) == 0)
        let folder = dir.appendingPathComponent(".git/objects/dd")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Pack header: blob (type 3), size 1024 (0x400).
        try Data([0xB0, 0x40]).write(to: folder.appendingPathComponent(String(repeating: "d", count: 38)))
        return oid
    }

    @Test("depth-first tree order preserves every path sharing a blob")
    func treeOrderAndMultiplicity() async throws {
        try await withRepo { dir, client in
            for path in ["a/nested/one.dat", "a/two.dat", "b/three.dat", "z.dat"] {
                try write(Self.first.encoded, path, in: dir)
            }
            try await commit(client)
            let pointers = try await GitScanner(client: client).scanTree("HEAD")
            #expect(pointers.map(\.name) == ["a/nested/one.dat", "a/two.dat", "b/three.dat", "z.dat"])
            #expect(Set(pointers.map(\.oid)).count == 1)
            #expect(pointers.allSatisfy { $0.oid.count == 40 && $0.pointer == Self.first })
            #expect(pointers.allSatisfy { $0.status.isEmpty && $0.sourceName.isEmpty })
            let filtered = try await GitScanner(client: client, filter: FilepathFilter(exclude: ["a"]))
                .scanTree()
            #expect(filtered.map(\.name) == ["b/three.dat", "z.dat"])
        }
    }

    @Test("malformed pointers are skipped, empty pointers and 1023 bytes survive")
    func decodingAndCutoff() async throws {
        try await withRepo { dir, client in
            for (index, rejection) in PointerRejection.all.enumerated() {
                try write(rejection.text, "bad-\(index)", in: dir)
            }
            try write("", "empty", in: dir)
            for size in [1023, 1024, 1025] {
                let text = Self.first.encoded
                    + String(repeating: " ", count: size - Self.first.encoded.utf8.count)
                // All three decode if read, so the scanner must gate on metadata.
                #expect(try Pointer.decode(Data(text.utf8)).oid == Self.first.oid)
                try write(text, "padded-\(size)", in: dir)
            }
            try await commit(client)
            let pointers = try await GitScanner(client: client).scanTree()
            #expect(pointers.map(\.name) == ["empty", "padded-1023"])
            #expect(pointers.first?.pointer == .empty)
            #expect(pointers.last?.pointer.oid == Self.first.oid)
            #expect(pointers.last?.pointer.canonical == false)
        }
    }

    @Test("oversized blobs are rejected from their ODB header without reading the payload")
    func cutoffUsesObjectHeader() async throws {
        try await withRepo { dir, client in
            var blob = try truncatedCutoffBlob(in: dir)
            var tree = try await standaloneTree(client, blob: &blob, path: "large.dat")
            let treeOID = String(cString: git_oid_tostr_s(&tree))
            #expect(try await GitScanner(client: client).scanTree(treeOID).isEmpty)
        }
    }

    @Test("cached destinations override the ref, independent of working files")
    func indexOverride() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "changed", in: dir)
            try write(Self.first.encoded, "unchanged", in: dir)
            try await commit(client)
            try write(Self.second.encoded, "changed", in: dir)
            try write(Self.second.encoded, "added", in: dir)
            try await client.add(paths: ["changed", "added"])
            try write("a downloaded working file", "changed", in: dir)
            try FileManager.default.removeItem(at: dir.appendingPathComponent("unchanged"))
            let pointers = try await GitScanner(client: client).scanIndex(ref: "HEAD", workingDirectory: dir)
            #expect(pointers.map(\.name) == ["added", "changed", "unchanged"])
            #expect(pointers.map(\.pointer.oid) == [Self.second.oid, Self.second.oid, Self.first.oid])
            #expect(pointers.map(\.status) == ["A", "M", ""])
            #expect(pointers.map(\.sourceName) == ["added", "changed", ""])
        }
    }

    @Test("index overrides compare canonically equivalent paths by Git bytes")
    func indexOverridePreservesPathBytes() async throws {
        try await withRepo { _, client in
            let decomposed = "cafe\u{0301}.dat"
            let composed = decomposed.precomposedStringWithCanonicalMapping
            var original = try await standaloneBlob(client, pointer: Self.first)
            var tree = try await standaloneTree(client, blob: &original, path: decomposed)
            let treeOID = String(cString: git_oid_tostr_s(&tree))
            var staged = try await standaloneBlob(client, pointer: Self.second)
            try await addIndexBlob(client, path: composed, blob: &staged)

            let pointers = try await GitScanner(client: client).scanIndex(ref: treeOID)
            #expect(pointers.count == 2)
            #expect(pointers.map { Array($0.name.utf8) } == [
                Array(composed.utf8), Array(decomposed.utf8)
            ])
            #expect(pointers.map(\.pointer) == [Self.second, Self.first])
        }
    }

    @Test("staged deletions and non-pointer replacements retain the ref pointer")
    func stagedDelete() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "deleted", in: dir)
            try write(Self.first.encoded, "replaced", in: dir)
            try await commit(client)
            try await client.remove(paths: ["deleted"])
            try write("ordinary git data", "replaced", in: dir)
            try await client.add(paths: ["replaced"])
            let pointers = try await GitScanner(client: client).scanIndex()
            #expect(pointers.map(\.name) == ["deleted", "replaced"])
            #expect(pointers.allSatisfy { $0.pointer == Self.first && $0.status.isEmpty })
        }
    }

    @Test("rename destination carries source name and diff status")
    func renameFields() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "old", in: dir)
            try await commit(client)
            try await client.move(from: "old", to: "new")
            let pointers = try await GitScanner(client: client).scanIndex()
            #expect(pointers.map(\.name) == ["new", "old"])
            #expect(pointers.first?.sourceName == "old")
            #expect(pointers.first?.status == "R")
            #expect(pointers.first?.oid == pointers.last?.oid)
        }
    }

    @Test("unborn HEAD is empty, with staged additions available to index scans")
    func unborn() async throws {
        try await withRepo { dir, client in
            let scanner = GitScanner(client: client)
            #expect(try await scanner.scanIndex().isEmpty)
            #expect(try await scanner.scanAll().isEmpty)
            #expect(try await scanner.scanRefs(include: ["HEAD"]).isEmpty)
            try write(Self.first.encoded, "added", in: dir)
            try await client.add(paths: ["added"])
            let pointers = try await scanner.scanIndex()
            #expect(pointers.map(\.name) == ["added"])
            #expect(pointers.first?.status == "A")
        }
    }

    @Test("bad revisions and repository errors propagate")
    func invalidRefs() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "file", in: dir)
            try await commit(client)
            let scanner = GitScanner(client: client)
            await #expect(throws: (any Error).self) { try await scanner.scanTree("missing-ref") }
            await #expect(throws: (any Error).self) { try await scanner.scanIndex(ref: "missing-ref") }
            await #expect(throws: (any Error).self) { try await scanner.scanRefs(include: ["missing-ref"]) }
            await #expect(throws: (any Error).self) {
                try await scanner.scanRefs(include: ["HEAD"], exclude: ["missing-ref"])
            }
            let notRepo = GitScanner(client: GitClient(workingDirectory: dir.appendingPathComponent("absent")))
            await #expect(throws: (any Error).self) { try await notRepo.scanAll() }
        }
    }

    @Test("missing Git blobs throw rather than being mistaken for invalid pointers")
    func missingBlob() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "file", in: dir)
            try await commit(client)
            let oid = try await client.resolveOID("HEAD:file")
            let object = dir.appendingPathComponent(".git/objects/\(oid.prefix(2))/\(oid.dropFirst(2))")
            try FileManager.default.moveItem(at: object, to: dir.appendingPathComponent("saved-object"))
            let scanner = GitScanner(client: client)
            await #expect(throws: (any Error).self) { try await scanner.scanTree() }
            await #expect(throws: (any Error).self) { try await scanner.scanIndex() }
            await #expect(throws: (any Error).self) { try await scanner.scanRefs(include: ["HEAD"]) }
        }
    }

    @Test("gitlinks are skipped in both trees and cached diffs")
    func gitlinks() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "file", in: dir)
            let target = try await commit(client)
            try await addGitlink(client, target: target)
            let scanner = GitScanner(client: client)
            #expect(try await scanner.scanIndex().map(\.name) == ["file"])
            try await client.commit(message: "gitlink", author: nil, allowEmpty: false)
            #expect(try await scanner.scanTree().map(\.name) == ["file"])
        }
    }

    @Test("history retains deleted pointer versions in rev-list order")
    func historicalVersions() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "file", in: dir)
            try await commit(client)
            try write(Self.second.encoded, "file", in: dir)
            try await commit(client, "modify")
            try await client.remove(paths: ["file"])
            try await commit(client, "delete")
            let pointers = try await GitScanner(client: client).scanRefs(include: ["HEAD"])
            #expect(pointers.map(\.name) == ["file", "file"])
            #expect(pointers.map(\.pointer) == [Self.second, Self.first])
            #expect(Set(pointers.map(\.oid)).count == 2)
        }
    }

    @Test("ranges exclude shared blobs reachable from excluded ancestors")
    func excludedObjectClosure() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "original", in: dir)
            let ancestor = try await commit(client)
            try await client.remove(paths: ["original"])
            let excluded = try await commit(client, "delete")
            try write(Self.first.encoded, "resurrected", in: dir)
            try write(Self.second.encoded, "new", in: dir)
            try await commit(client, "reintroduce shared blob")
            let scanner = GitScanner(client: client)
            let range = try await scanner.scanRefs(include: ["HEAD"], exclude: [excluded])
            #expect(range.map(\.name) == ["new"])
            #expect(range.first?.pointer == Self.second)
            let history = try await scanner.scanRefs(include: ["HEAD"])
            #expect(history.map(\.name) == ["new", "resurrected"])
            #expect(try await scanner.scanRefs(include: [ancestor]).map(\.name) == ["original"])
        }
    }

    @Test("a filtered first path consumes the OID for the whole history walk")
    func filteredNamesConsumeOID() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "z-allowed", in: dir)
            try await commit(client)
            try write(Self.first.encoded, "a-rejected", in: dir)
            try await commit(client, "copy")
            let scanner = GitScanner(client: client, filter: FilepathFilter(include: ["z-allowed"]))
            #expect(try await scanner.scanRefs(include: ["HEAD"]).isEmpty)
            #expect(try await scanner.scanTree().map(\.name) == ["z-allowed"])
        }
    }

    @Test("scanAll combines branch, tag and detached HEAD in one walk")
    func allReferences() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "old", in: dir)
            let old = try await commit(client)
            try await client.tagCreate(name: "old-tag", target: old)
            try await client.remove(paths: ["old"])
            try await commit(client, "delete")
            try await client.checkout(ref: old)
            try write(Self.second.encoded, "detached", in: dir)
            try await commit(client, "detached")
            let starts = try await client.references().map(\.targetSHA) + ["HEAD"]
            let scanner = GitScanner(client: client)
            let expected = try await scanner.scanRefs(include: starts)
            let all = try await scanner.scanAll()
            #expect(all == expected)
            #expect(Set(all.map(\.pointer.oid)) == [Self.first.oid, Self.second.oid])
            #expect(all.count == 2)
        }
    }

    @Test("scanAll preserves direct blob and tree refs in an unborn repository")
    func allNonCommitReferences() async throws {
        try await withRepo { _, client in
            var directBlob = try await standaloneBlob(client, pointer: Self.first)
            var nestedBlob = try await standaloneBlob(client, pointer: Self.second)
            var directTree = try await standaloneTree(client, blob: &nestedBlob)
            try await addReference(client, name: "refs/custom/blob", target: &directBlob)
            try await addReference(client, name: "refs/custom/tree", target: &directTree)

            let pointers = try await GitScanner(client: client).scanAll()
            #expect(pointers.map(\.name) == ["", "nested.dat"])
            #expect(pointers.map(\.pointer) == [Self.first, Self.second])
            #expect(pointers.map(\.oid).allSatisfy { $0.count == 40 })
        }
    }

    @Test("scanAll visits direct roots before commit trees for shared blob OIDs")
    func allNonCommitReferencesPrecedeHistory() async throws {
        try await withRepo { dir, client in
            try write(Self.first.encoded, "branch.dat", in: dir)
            try await commit(client)
            var blob = git_oid()
            let blobOID = try await client.resolveOID("HEAD:branch.dat")
            #expect(git_oid_fromstr(&blob, blobOID) == 0)
            var tree = try await standaloneTree(client, blob: &blob)
            try await addReference(client, name: "refs/tags/tree", target: &tree)

            let scanner = GitScanner(
                client: client, filter: FilepathFilter(include: ["nested.dat"]))
            let pointers = try await scanner.scanAll()
            #expect(pointers.map(\.name) == ["nested.dat"])
            #expect(pointers.first?.pointer == Self.first)
        }
    }

    @Test("scanRefs walks tree and blob roots, and excludes what excluded roots reach")
    func refsNonCommitRoots() async throws {
        try await withRepo { dir, client in
            var directBlob = try await standaloneBlob(client, pointer: Self.first)
            var nestedBlob = try await standaloneBlob(client, pointer: Self.second)
            var directTree = try await standaloneTree(client, blob: &nestedBlob)
            try await addReference(client, name: "refs/tags/blob", target: &directBlob)
            try await addReference(client, name: "refs/tags/data", target: &directTree)
            let scanner = GitScanner(client: client)

            let tree = try await scanner.scanRefs(include: ["refs/tags/data"])
            #expect(tree.map(\.name) == ["nested.dat"])
            #expect(tree.map(\.pointer) == [Self.second])
            let blob = try await scanner.scanRefs(include: ["refs/tags/blob"])
            #expect(blob.map(\.pointer) == [Self.first])

            // A commit whose tree holds the same blob is excluded by the tree root.
            try write(Self.second.encoded, "nested.dat", in: dir)
            let head = try await commit(client)
            #expect(try await scanner.scanRefs(include: [head], exclude: ["refs/tags/data"]).isEmpty)
            #expect(try await scanner.scanRefs(include: ["refs/tags/data"], exclude: [head]).isEmpty)
        }
    }
}
