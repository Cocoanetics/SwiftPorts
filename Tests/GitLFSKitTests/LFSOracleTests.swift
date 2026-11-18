// Ours against the system git-lfs: pointer bytes, rejection texts and
// store locations. Skipped where `git lfs version` doesn't run.
#if os(macOS) || os(Linux)
import Foundation
import Testing
import SwiftGit
@testable import GitLFSKit

@Suite("git-lfs oracle", .enabled(if: LFSOracle.isAvailable, "git-lfs is not on PATH"))
struct LFSOracleTests {
    let oracle = LFSOracle()

    /// Contents to point at: empty, small, binary, around and well past the
    /// pointer size cutoff.
    static let contents: [Data] = [
        Data(),
        Data("hello\n".utf8),
        Data((0..<256).map { UInt8($0) }),
        Data(repeating: 0x61, count: 1023),
        Data(repeating: 0x62, count: 1024),
        Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    ]

    private func canonicalPath(_ path: String) -> String {
        var path = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func ourPointer(for content: Data, in dir: URL) throws -> Pointer {
        let file = dir.appendingPathComponent("content-\(UUID().uuidString)")
        try content.write(to: file)
        let (oid, size) = try LocalStore.sha256(of: file)
        return Pointer(oid: oid, size: size)
    }

    @Test("pointer bytes equal `git lfs pointer --file`", arguments: contents.indices)
    func pointerFile(_ index: Int) throws {
        let dir = try oracle.makeDirectory("pointer-\(index)")
        let file = dir.appendingPathComponent("file")
        try Self.contents[index].write(to: file)
        let result = try oracle.run(["lfs", "pointer", "--file=\(file.path)"], in: dir)
        #expect(result.status == 0, "\(result.err)")
        let ours = try ourPointer(for: Self.contents[index], in: dir)
        #expect(Data(ours.encoded.utf8) == result.out)
    }

    @Test("pointer bytes equal `git lfs clean` output", arguments: contents.indices)
    func clean(_ index: Int) throws {
        let repo = try oracle.makeDirectory("clean-\(index)")
        try oracle.git(["init", "-q", "-b", "main"], in: repo)
        let result = try oracle.run(["lfs", "clean", "--", "file.bin"], in: repo, input: Self.contents[index])
        #expect(result.status == 0, "\(result.err)")
        let ours = try ourPointer(for: Self.contents[index], in: repo)
        #expect(Data(ours.encoded.utf8) == result.out)
        // What `clean` stored is where ours looks for it.
        if !Self.contents[index].isEmpty {
            let store = LocalStore(gitStorageDirectory: repo.appendingPathComponent(".git"))
            let stored = try Data(contentsOf: store.objectPathname(ours.oid))
            #expect(stored == Self.contents[index])
        }
    }

    @Test("our decoded pointers re-encode to what git-lfs accepts as canonical")
    func strictCheck() throws {
        let dir = try oracle.makeDirectory("strict")
        let text = try ourPointer(for: Data("hello\n".utf8), in: dir).encoded
        let file = dir.appendingPathComponent("pointer")
        try Data(text.utf8).write(to: file)
        let result = try oracle.run(["lfs", "pointer", "--check", "--strict", "--file=\(file.path)"], in: dir)
        #expect(result.status == 0)
        #expect(try Pointer.decode(Data(text.utf8)).canonical)
    }

    @Test("rejection texts equal `git lfs pointer --pointer`'s", arguments: PointerRejection.all)
    func rejection(_ rejection: PointerRejection) throws {
        let dir = try oracle.makeDirectory("reject-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("p")
        try Data(rejection.text.utf8).write(to: file)
        let result = try oracle.run(["lfs", "pointer", "--pointer=\(file.path)"], in: dir)
        #expect(result.status == 1)
        let theirs = result.err.split(separator: "\n").last.map(String.init)
        #expect(theirs == rejection.error)
    }

    @Test("store locations equal `git lfs env`'s, in a plain repo, a linked worktree and with lfs.storage")
    func storeLocations() async throws {
        let repo = try oracle.makeDirectory("env")
        try oracle.git(["init", "-q", "-b", "main"], in: repo)
        try oracle.git(["-c", "user.name=T", "-c", "user.email=t@example.com",
                        "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        let linked = oracle.root.appendingPathComponent("env-linked")
        try oracle.git(["worktree", "add", "-q", "-b", "feature", linked.path], in: repo)

        for storage in [nil, "custom-lfs", oracle.root.appendingPathComponent("elsewhere").path] {
            if let storage {
                try oracle.git(["config", "lfs.storage", storage], in: repo)
            }
            for dir in [repo, linked] {
                let theirs = try oracle.lfsEnvironment(in: dir)
                let ours = try await LocalStore.open(GitClient(workingDirectory: dir))
                #expect(canonicalPath(ours.storageDirectory.path)
                        == canonicalPath(try #require(theirs["LfsStorageDir"])))
                #expect(canonicalPath(ours.temporaryDirectory.path) == canonicalPath(try #require(theirs["TempDir"])))
                #expect(canonicalPath(ours.gitStorageDirectory.path)
                        == canonicalPath(try #require(theirs["LocalGitStorageDir"])))
            }
        }
    }
}
#endif
