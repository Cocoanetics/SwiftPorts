import Foundation
import GitKit
import GitLFSKit
import GitLFSTestSupport
import ShellKit
import Testing

extension PublicOperationTests {
    @Test("private worktree config stays separate from shared common-dir LFS storage")
    func privateWorktreeConfigVsSharedStorage() async throws {
        try await NativeFixture.run { fixture, server in
            let commit = try await GitLFSKit.withOperation(shell: fixture.shell) { operation -> String in
                let directory = fixture.path("source")
                return try operation.createRepository(at: directory, using: { _ in
                    try Repository.initialize(at: directory, initialBranch: "main")
                }, { repository in
                    try repository.configSet("core.repositoryformatversion", "1")
                    try repository.configSet("extensions.worktreeConfig", "true")
                    try Data("*.lfs filter=lfs -text\n".utf8)
                        .write(to: directory.appendingPathComponent(".gitattributes"))
                    try NativeFixture.bytes.write(to: directory.appendingPathComponent("a.lfs"))
                    try NativeFixture.otherBytes.write(to: directory.appendingPathComponent("b.lfs"))
                    try repository.add(paths: [])
                    return try repository.commitDetailed(
                        message: "two lfs files", author: NativeFixture.signature,
                        allowEmpty: false, sign: .noSign).sha
                })
            }
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
            server.store(NativeFixture.otherBytes, oid: NativeFixture.otherPointer.oid)
            let sharedStore = fixture.store("source")
            try FileManager.default.removeItem(at: sharedStore.objectPathname(NativeFixture.pointer.oid))
            try FileManager.default.removeItem(at: sharedStore.objectPathname(NativeFixture.otherPointer.oid))

            let wtA = fixture.path("wt-a")
            let wtB = fixture.path("wt-b")
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try operation.authorize(wtA)
                try operation.authorize(wtB)
                try operation.withRepository(at: fixture.path("source")) { primary in
                    _ = try primary.worktreeAdd(
                        path: wtA, branch: "branch-a", startPoint: commit, preparation: operation.preparation)
                    _ = try primary.worktreeAdd(
                        path: wtB, branch: "branch-b", startPoint: commit, preparation: operation.preparation)
                }
                // Give each linked worktree its own private config.worktree.
                let gitDirA = try operation.withRepository(at: wtA) { try #require(try $0.gitDir()) }
                let gitDirB = try operation.withRepository(at: wtB) { try #require(try $0.gitDir()) }
                try "[consumer]\n\tprivate = wt-a\n[lfs]\n\tfetchexclude = b.lfs\n".write(
                    to: URL(fileURLWithPath: gitDirA).appendingPathComponent("config.worktree"),
                    atomically: true, encoding: .utf8)
                try "[consumer]\n\tprivate = wt-b\n[lfs]\n\tfetchexclude = a.lfs\n".write(
                    to: URL(fileURLWithPath: gitDirB).appendingPathComponent("config.worktree"),
                    atomically: true, encoding: .utf8)

                try operation.withRepository(at: fixture.path("source")) { primary throws in
                    #expect(try primary.configGet("consumer.private") == nil)
                }
                try operation.withRepository(at: wtA) { repoA throws in
                    #expect(try repoA.configGet("consumer.private") == "wt-a")
                    try FileManager.default.removeItem(at: wtA.appendingPathComponent("a.lfs"))
                    try FileManager.default.removeItem(at: wtA.appendingPathComponent("b.lfs"))
                    try repoA.checkoutPaths(["a.lfs", "b.lfs"])
                    #expect(try Data(contentsOf: wtA.appendingPathComponent("a.lfs")) == NativeFixture.bytes)
                    #expect(try Data(contentsOf: wtA.appendingPathComponent("b.lfs"))
                            == Data(NativeFixture.otherPointer.encoded.utf8))
                    // Staging a new file in wt-a inserts into the shared common-dir store.
                    try NativeFixture.thirdBytes.write(to: wtA.appendingPathComponent("c.lfs"))
                    try repoA.add(paths: ["c.lfs"])
                    _ = try repoA.commitDetailed(
                        message: "c in wt-a", author: NativeFixture.signature, allowEmpty: false, sign: .noSign)
                }
                try operation.withRepository(at: wtB) { repoB throws in
                    #expect(try repoB.configGet("consumer.private") == "wt-b")
                    try FileManager.default.removeItem(at: wtB.appendingPathComponent("a.lfs"))
                    try FileManager.default.removeItem(at: wtB.appendingPathComponent("b.lfs"))
                    try repoB.checkoutPaths(["a.lfs", "b.lfs"])
                    #expect(try Data(contentsOf: wtB.appendingPathComponent("a.lfs"))
                            == Data(NativeFixture.pointer.encoded.utf8))
                    #expect(try Data(contentsOf: wtB.appendingPathComponent("b.lfs")) == NativeFixture.otherBytes)
                }
                // Objects live in the shared common-dir store, not in private worktree git dirs.
                #expect(try Data(contentsOf: sharedStore.objectPathname(NativeFixture.thirdPointer.oid))
                        == NativeFixture.thirdBytes)
                #expect(!FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: gitDirA).appendingPathComponent("lfs").path))
                #expect(!FileManager.default.fileExists(
                    atPath: URL(fileURLWithPath: gitDirB).appendingPathComponent("lfs").path))
            }
        }
    }

    @Test("existing and missing recursive submodules keep their own repository and LFS store identity")
    func recursiveSubmodules() async throws {
        try await NativeFixture.run { fixture, server in
            server.store(NativeFixture.bytes, oid: NativeFixture.pointer.oid)
            server.store(NativeFixture.otherBytes, oid: NativeFixture.otherPointer.oid)
            server.store(NativeFixture.thirdBytes, oid: NativeFixture.thirdPointer.oid)
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                _ = try fixture.seed(operation, name: "parent-src", file: "p.lfs",
                                     bytes: NativeFixture.bytes, pointer: NativeFixture.pointer)
                _ = try fixture.seed(operation, name: "outer-src", file: "o.lfs",
                                     bytes: NativeFixture.otherBytes, pointer: NativeFixture.otherPointer)
                _ = try fixture.seed(operation, name: "nested-src", file: "n.lfs",
                                     bytes: NativeFixture.thirdBytes, pointer: NativeFixture.thirdPointer)
                try operation.withRepository(at: fixture.path("nested-src")) { repo in
                    try Data("line\n".utf8).write(to: fixture.path("nested-src/plain.txt"))
                    try repo.add(paths: ["plain.txt"])
                    _ = try repo.commitDetailed(
                        message: "nested plain", author: NativeFixture.signature, allowEmpty: false, sign: .noSign)
                }
                // Record .gitmodules and real gitlinks (mode 160000) in outer-src and parent-src.
                let outerNested = fixture.path("outer-src/nested")
                try operation.createRepository(at: outerNested, using: { preparation in
                    try Repository.clone(
                        from: fixture.path("nested-src"), to: outerNested, progress: { _ in }, preparation: preparation)
                }, { _ in })
                try operation.withRepository(at: fixture.path("outer-src")) { repo in
                    try "[submodule \"nested\"]\n\tpath = nested\n\turl = \(fixture.path("nested-src").path)\n"
                        .write(to: fixture.path("outer-src/.gitmodules"), atomically: true, encoding: .utf8)
                    try repo.add(paths: [".gitmodules", "nested"])
                    _ = try repo.commitDetailed(
                        message: "outer modules", author: NativeFixture.signature, allowEmpty: false, sign: .noSign)
                }
                let parentOuter = fixture.path("parent-src/outer")
                try operation.createRepository(at: parentOuter, using: { preparation in
                    try Repository.clone(
                        from: fixture.path("outer-src"), to: parentOuter, progress: { _ in }, preparation: preparation)
                }, { _ in })
                try operation.withRepository(at: fixture.path("parent-src")) { repo in
                    try "[submodule \"outer\"]\n\tpath = outer\n\turl = \(fixture.path("outer-src").path)\n"
                        .write(to: fixture.path("parent-src/.gitmodules"), atomically: true, encoding: .utf8)
                    try repo.add(paths: [".gitmodules", "outer"])
                    _ = try repo.commitDetailed(
                        message: "parent modules", author: NativeFixture.signature, allowEmpty: false, sign: .noSign)
                }
            }

            // 1. Missing recursive submodules: clone parent (submodules absent), sync tolerates missing,
            // then clone outer and nested with creation-time config before initial checkout.
            fixture.shell.environment["GIT_CONFIG_COUNT"] = "2"
            fixture.shell.environment["GIT_CONFIG_KEY_1"] = "core.autocrlf"
            fixture.shell.environment["GIT_CONFIG_VALUE_1"] = "true"
            let parentClone = fixture.path("parent-clone")
            let outerDir = parentClone.appendingPathComponent("outer")
            let nestedDir = outerDir.appendingPathComponent("nested")
            try await GitLFSKit.withOperation(shell: fixture.shell) { operation in
                try operation.authorize(fixture.path("parent-src"))
                try operation.authorize(fixture.path("outer-src"))
                try operation.authorize(fixture.path("nested-src"))
                try operation.createRepository(at: parentClone, using: { preparation in
                    try Repository.clone(
                        from: fixture.path("parent-src"), to: parentClone, progress: { _ in }, preparation: preparation)
                }, { parentRepo in
                    try parentRepo.submoduleSync(recursive: true)
                    #expect(try Data(contentsOf: parentClone.appendingPathComponent("p.lfs")) == NativeFixture.bytes)
                })
                try operation.createRepository(at: outerDir, using: { preparation in
                    try Repository.clone(
                        from: fixture.path("outer-src"), to: outerDir, progress: { _ in }, preparation: preparation)
                }, { outerRepo in
                    try outerRepo.submoduleSync(recursive: true)
                    #expect(try Data(contentsOf: outerDir.appendingPathComponent("o.lfs")) == NativeFixture.otherBytes)
                })
                try operation.createRepository(at: nestedDir, using: { preparation in
                    try Repository.clone(
                        from: fixture.path("nested-src"), to: nestedDir, progress: { _ in }, preparation: preparation)
                }, { nestedRepo throws in
                    #expect(try nestedRepo.configGet("core.autocrlf") == "true")
                    #expect(try Data(contentsOf: nestedDir.appendingPathComponent("plain.txt"))
                            == Data("line\r\n".utf8))
                    #expect(try Data(contentsOf: nestedDir.appendingPathComponent("n.lfs")) == NativeFixture.thirdBytes)
                })

                // 2. Existing recursive submodules: sync recursively and reopen each handle.
                try operation.withRepository(at: parentClone) { try $0.submoduleSync(recursive: true) }
                try operation.withRepository(at: outerDir) { outerRepo throws in
                    #expect(try outerRepo.configGet("consumer.operation") == "scoped")
                    #expect(try outerRepo.status().isClean)
                }
                try operation.withRepository(at: nestedDir) { nestedRepo throws in
                    #expect(try nestedRepo.configGet("consumer.operation") == "scoped")
                    #expect(try nestedRepo.status().isClean)
                }
            }

            // Each repository keeps its own distinct LFS store.
            let parentStore = LocalStore(gitStorageDirectory: parentClone.appendingPathComponent(".git"))
            let outerStore = LocalStore(gitStorageDirectory: outerDir.appendingPathComponent(".git"))
            let nestedStore = LocalStore(gitStorageDirectory: nestedDir.appendingPathComponent(".git"))
            #expect(FileManager.default.fileExists(atPath: parentStore.objectPathname(NativeFixture.pointer.oid).path))
            #expect(!FileManager.default.fileExists(
                atPath: parentStore.objectPathname(NativeFixture.otherPointer.oid).path))
            #expect(FileManager.default.fileExists(
                atPath: outerStore.objectPathname(NativeFixture.otherPointer.oid).path))
            #expect(!FileManager.default.fileExists(
                atPath: outerStore.objectPathname(NativeFixture.thirdPointer.oid).path))
            #expect(FileManager.default.fileExists(
                atPath: nestedStore.objectPathname(NativeFixture.thirdPointer.oid).path))
            #expect(!FileManager.default.fileExists(
                atPath: nestedStore.objectPathname(NativeFixture.pointer.oid).path))
        }
    }
}
