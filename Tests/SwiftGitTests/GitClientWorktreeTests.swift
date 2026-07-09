import Foundation
import Testing
@testable import SwiftGit

@Suite("GitClient.worktree")
struct GitClientWorktreeTests {

    private func tmpDir(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }

    private func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    private func canonicalPathIfPresent(_ url: URL?) -> String? {
        url.map(canonicalPath)
    }

    private func makeRepo() async throws -> URL {
        let dir = tmpDir("GitClientWorktree")
        let client = SwiftGit.GitClient(workingDirectory: dir)
        try await client.initRepository(initialBranch: "main")
        try await client.configSet("user.email", "test@example.com")
        try await client.configSet("user.name", "Test")
        try Data("hi\n".utf8).write(to: dir.appendingPathComponent("README.md"))
        try await client.add(paths: ["README.md"])
        _ = try await client.commit(message: "init", author: nil, allowEmpty: false)
        return dir
    }

    @Test("add, list, remove linked worktree")
    func addListRemove() async throws {
        let dir = try await makeRepo()
        let linked = tmpDir("GitClientLinkedWorktree")
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { try? FileManager.default.removeItem(at: linked) }

        let client = SwiftGit.GitClient(workingDirectory: dir)
        try await client.worktreeAdd(path: linked, branch: "feature/worktree")

        let entries = try await client.worktreeList()
        #expect(entries.count == 2)
        #expect(entries.first?.isMain == true)
        let worktree = try #require(entries.first { $0.name == linked.lastPathComponent })
        #expect(worktree.branch == "feature/worktree")
        #expect(worktree.isMain == false)
        #expect(worktree.isLocked == false)
        #expect(worktree.isPrunable == false)
        #expect(FileManager.default.fileExists(atPath: linked.path))

        try await client.worktreeRemove(name: worktree.name)
        #expect(!FileManager.default.fileExists(atPath: linked.path))
        #expect(try await client.worktreeList().count == 1)
    }

    @Test("remove refuses dirty linked worktree unless forced")
    func removeDirtyRequiresForce() async throws {
        let dir = try await makeRepo()
        let linked = tmpDir("GitClientDirtyWorktree")
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { try? FileManager.default.removeItem(at: linked) }

        let client = SwiftGit.GitClient(workingDirectory: dir)
        try await client.worktreeAdd(path: linked, branch: "dirty-worktree")
        let worktree = try #require(
            try await client.worktreeList().first { $0.name == linked.lastPathComponent })

        try Data("local\n".utf8).write(to: linked.appendingPathComponent("local.txt"))
        await #expect(throws: Libgit2Error.self) {
            try await client.worktreeRemove(name: worktree.name)
        }
        #expect(FileManager.default.fileExists(atPath: linked.path))

        try await client.worktreeRemove(name: worktree.name, force: true)
        #expect(!FileManager.default.fileExists(atPath: linked.path))
    }

    @Test("list from linked worktree still reports primary worktree first")
    func listFromLinkedWorktree() async throws {
        let dir = try await makeRepo()
        let linked = tmpDir("GitClientNestedListWorktree")
        defer { try? FileManager.default.removeItem(at: dir) }
        defer { try? FileManager.default.removeItem(at: linked) }

        let mainClient = SwiftGit.GitClient(workingDirectory: dir)
        try await mainClient.worktreeAdd(path: linked, branch: "feature/list-from-linked")

        let linkedClient = SwiftGit.GitClient(workingDirectory: linked)
        let entries = try await linkedClient.worktreeList()
        #expect(entries.count == 2)
        #expect(entries.first?.isMain == true)
        #expect(canonicalPathIfPresent(entries.first?.path) == canonicalPath(dir))
        #expect(entries.first?.branch == "main")
        #expect(canonicalPathIfPresent(entries.dropFirst().first?.path) == canonicalPath(linked))
        #expect(entries.dropFirst().first?.branch == "feature/list-from-linked")
    }
}
