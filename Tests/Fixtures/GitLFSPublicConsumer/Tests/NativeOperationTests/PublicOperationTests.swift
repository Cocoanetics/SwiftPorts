import Foundation
import GitKit
import GitLFSKit
import GitLFSTestSupport
import ShellKit
import Testing

@Suite("Native GitKit public operations", .serialized, .timeLimit(.minutes(2)))
struct PublicOperationTests {
    @Test("direct clone, worktree bootstrap, detached checkout, reused slots and staging share isolation")
    func nativeOperations() async throws {
        try await NativeFixture.run { fixture, server in
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                let first = try fixture.seed(operation)
                server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
                try FileManager.default.removeItem(at: fixture.store().objectPathname(NativeFixture.pointer.oid))
                let linked = fixture.path("linked")
                let holder = fixture.path("holder")
                try operation.authorize(linked)
                try operation.authorize(holder)
                try operation.withRepository(at: fixture.path("source")) { repository in
                    // A non-default start point; bootstrapping prepares and filters
                    // before the new worktree's first checkout.
                    _ = try repository.worktreeAdd(
                        path: linked, branch: "review", startPoint: first, preparation: operation.preparation)
                    _ = try repository.worktreeAdd(
                        path: holder, branch: "holder", startPoint: first, preparation: operation.preparation)
                    #expect(try repository.status().isClean)
                    #expect(try repository.diff(.workdirVsIndex).isEmpty)
                }
                #expect(server.requests().filter { $0.method == "GET" }.count == 1)
                // Reused worktree with reset of another branch-holder, plus detached checkout.
                try operation.withRepository(at: holder) { repository in
                    #expect(try repository.configGet("consumer.operation") == "scoped")
                    #expect(try Data(contentsOf: holder.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                    try repository.checkout(ref: first)
                    #expect(try repository.currentBranch() == nil)
                    _ = try repository.reset(to: first, mode: .hard)
                    #expect(try repository.status().isClean)
                }
                try operation.withRepository(at: linked) { repository in
                    #expect(try repository.configGet("consumer.operation") == "scoped")
                    #expect(try Data(contentsOf: linked.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                    try repository.checkout(ref: first)
                    #expect(try repository.currentBranch() == nil)
                    // Take over the branch released by the detached branch-holder worktree.
                    try repository.checkout(ref: "holder")
                    #expect(try repository.currentBranch() == "holder")
                    try repository.checkoutNewBranch(name: "linked-reused", startPoint: first)
                    _ = try repository.reset(to: first, mode: .hard)
                    #expect(try repository.status().isClean)
                }
                try operation.withRepository(at: linked) { repository in
                    try NativeFixture.otherBytes.write(to: linked.appendingPathComponent("new.lfs"))
                    try repository.add(paths: ["new.lfs"])
                    _ = try repository.commitDetailed(message: "new", author: NativeFixture.signature,
                                                       allowEmpty: false, sign: .noSign)
                    #expect(try repository.catFileBlob("HEAD:new.lfs") == Data(NativeFixture.otherPointer.encoded.utf8))
                    #expect(try Data(contentsOf: fixture.store().objectPathname(NativeFixture.otherPointer.oid))
                            == NativeFixture.otherBytes)
                    #expect(try repository.status().isClean)
                }
                // Initial clone starts with a nonexistent destination and uses only
                // native GitKit APIs. Its store must not be the parent's store.
                let clone = fixture.path("clone")
                try operation.authorize(fixture.path("source"))
                try operation.createRepository(at: clone, using: { preparation in
                    try Repository.clone(
                        from: fixture.path("source"), to: clone, progress: { _ in }, preparation: preparation)
                }, { repository throws in
                    #expect(try repository.configGet("consumer.operation") == "scoped")
                    #expect(try repository.status().isClean)
                    #expect(try Data(contentsOf: clone.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                    #expect(try Data(contentsOf: fixture.store("clone").objectPathname(NativeFixture.pointer.oid))
                            == NativeFixture.bytes)
                })
                #expect(server.requests().filter { $0.method == "GET" }.count == 2)
            }
        }
    }

    @Test("process-wide filter runs clean paths on status and diff and fails without operation scope")
    func statusAndDiffCleanPaths() async throws {
        try await NativeFixture.run { fixture, _ in
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation)
                let file = fixture.path("source/a.lfs")
                try operation.withRepository(at: fixture.path("source")) { repository in
                    // Modifying an LFS file on disk triggers clean filtering during status/diff.
                    try NativeFixture.otherBytes.write(to: file)
                    let modifiedStatus = try repository.status()
                    #expect(!modifiedStatus.isClean)
                    let diff = try repository.diff(.workdirVsIndex)
                    #expect(diff.contains(NativeFixture.pointer.oid))
                    #expect(diff.contains(NativeFixture.otherPointer.oid))
                    #expect(!diff.contains("hello"))
                    // Rewriting original content with a fresh mtime forces clean hashing
                    // and returns status/diff to clean.
                    try NativeFixture.bytes.write(to: file)
                    let future = Date().addingTimeInterval(10)
                    try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: file.path)
                    #expect(try repository.status().isClean)
                    #expect(try repository.diff(.workdirVsIndex).isEmpty)
                }
            }
            // Outside withOperation, clean filtering during status/diff fails rather than silently passing.
            let raw = try Repository.open(at: fixture.path("source"))
            // Same-size edit forces status() to hash/clean the working-tree file despite stat size matching.
            try Data("xyz".utf8).write(to: fixture.path("source/a.lfs"))
            #expect(throws: (any Error).self) { _ = try raw.status() }
            #expect(throws: (any Error).self) { _ = try raw.diff(.workdirVsIndex) }
        }
    }

    @Test("attributes without LFS commands pass through")
    func attributesOnly() async throws {
        try await NativeFixture.run { fixture, _ in
            fixture.shell.environment["GIT_CONFIG_GLOBAL"] = ""
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                let directory = fixture.path("plain")
                try operation.createRepository(at: directory, using: { _ in
                    try Repository.initialize(at: directory, initialBranch: "main")
                }, { repository in
                    try repository.configSet("user.name", "Public consumer")
                    try repository.configSet("user.email", "consumer@example.invalid")
                    try Data("*.lfs filter=lfs\n".utf8).write(to: directory.appendingPathComponent(".gitattributes"))
                    try NativeFixture.bytes.write(to: directory.appendingPathComponent("a.lfs"))
                    try repository.add(paths: [])
                    _ = try repository.commitDetailed(message: "plain", author: NativeFixture.signature,
                                                       allowEmpty: false, sign: .noSign)
                    #expect(try repository.catFileBlob("HEAD:a.lfs") == NativeFixture.bytes)
                    #expect(try repository.status().isClean)
                })
            }
        }
    }
}
