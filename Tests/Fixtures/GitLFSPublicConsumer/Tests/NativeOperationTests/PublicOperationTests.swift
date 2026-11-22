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
                    // A non-default start point; bootstrapping filters before the new
                    // worktree has been opened by the host.
                    try repository.worktreeAdd(path: linked, branch: "review", startPoint: first)
                    try repository.worktreeAdd(path: holder, branch: "holder", startPoint: first)
                    #expect(try repository.status().isClean)
                    _ = try repository.diff(.workdirVsIndex)
                }
                #expect(server.requests().filter { $0.method == "GET" }.count == 1)
                for directory in [linked, holder] {
                    try operation.withRepository(at: directory) { repository in
                        #expect(try repository.configGet("consumer.operation") == "scoped")
                        #expect(try Data(contentsOf: directory.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                        try repository.checkout(ref: first)
                        #expect(try repository.currentBranch() == nil)
                        try repository.checkoutNewBranch(
                            name: directory.lastPathComponent + "-reused", startPoint: first)
                        _ = try repository.reset(to: first, mode: .hard)
                        #expect(try repository.status().isClean)
                    }
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
                try operation.createRepository(at: clone, using: {
                    _ = try Repository.clone(from: fixture.path("source"), to: clone, progress: { _ in })
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

    @Test("attributes without LFS commands pass through")
    func attributesOnly() async throws {
        try await NativeFixture.run { fixture, _ in
            fixture.shell.environment["GIT_CONFIG_GLOBAL"] = ""
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                let directory = fixture.path("plain")
                try operation.createRepository(at: directory, using: {
                    _ = try Repository.initialize(at: directory, initialBranch: "main")
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
