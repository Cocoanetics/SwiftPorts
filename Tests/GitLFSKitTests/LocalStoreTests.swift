import Foundation
import Testing
import SwiftGit
@testable import GitLFSKit

@Suite("LocalStore")
struct LocalStoreTests {
    /// Every embedded git operation runs under this host's configuration.
    let host = IsolatedLFSHost()

    static let content = Data("hello\n".utf8)
    static let oid = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"

    private func tmpDir(_ prefix: String) -> URL {
        host.root.appendingPathComponent(IsolatedLFSHost.shortName(prefix))
    }

    /// The path with symlinks resolved, as far up as it exists.
    private func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL, missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var path = missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private func makeRepo() async throws -> URL {
        try await host.run {
            let dir = tmpDir("Repo")
            let client = GitClient(workingDirectory: dir)
            try await client.initRepository(initialBranch: "main")
            try await client.configSet("user.email", "test@example.com")
            try await client.configSet("user.name", "Test")
            try Data("hi\n".utf8).write(to: dir.appendingPathComponent("README.md"))
            try await client.add(paths: ["README.md"])
            _ = try await client.commit(message: "init", author: nil, allowEmpty: false)
            return dir
        }
    }

    @Test("a plain repository stores under .git/lfs")
    func plainRepository() async throws {
        try await host.run {
            let repo = try await makeRepo()
            let store = try await LocalStore.open(GitClient(workingDirectory: repo))
            let lfs = repo.appendingPathComponent(".git/lfs")
            #expect(canonicalPath(store.storageDirectory) == canonicalPath(lfs))
            #expect(canonicalPath(store.objectsDirectory) == canonicalPath(lfs.appendingPathComponent("objects")))
            #expect(canonicalPath(store.temporaryDirectory) == canonicalPath(lfs.appendingPathComponent("tmp")))
            #expect(canonicalPath(store.incompleteDirectory) == canonicalPath(lfs.appendingPathComponent("incomplete")))
            #expect(canonicalPath(store.objectPathname(Self.oid))
                    == canonicalPath(lfs.appendingPathComponent("objects/58/91/\(Self.oid)")))
            #expect(store.objectPathname(Pointer.emptyObjectSHA256) == LocalStore.nullDevice)
        }
    }

    @Test("a linked worktree shares the main repository's store")
    func linkedWorktree() async throws {
        try await host.run {
            let repo = try await makeRepo()
            let linked = tmpDir("Linked")
            try await GitClient(workingDirectory: repo).worktreeAdd(path: linked, branch: "feature")

            let linkedClient = GitClient(workingDirectory: linked)
            let gitDir = try #require(try await linkedClient.gitDir())
            let commonDir = try #require(try await linkedClient.commonDir())
            #expect(canonicalPath(URL(fileURLWithPath: gitDir)) != canonicalPath(URL(fileURLWithPath: commonDir)))
            #expect(canonicalPath(URL(fileURLWithPath: commonDir))
                    == canonicalPath(repo.appendingPathComponent(".git")))

            let main = try await LocalStore.open(GitClient(workingDirectory: repo))
            let shared = try await LocalStore.open(linkedClient)
            #expect(canonicalPath(shared.storageDirectory) == canonicalPath(main.storageDirectory))

            try await shared.store(Self.content, oid: Self.oid)
            #expect(try await main.objectExists(Self.oid, size: Int64(Self.content.count)))
        }
    }

    @Test("lfs.storage moves the store; a relative path is against the common dir")
    func lfsStorage() async throws {
        try await host.run {
            let repo = try await makeRepo()
            let client = GitClient(workingDirectory: repo)

            try await client.configSet("lfs.storage", "custom-lfs")
            let relative = try await LocalStore.open(client)
            #expect(canonicalPath(relative.storageDirectory)
                    == canonicalPath(repo.appendingPathComponent(".git/custom-lfs")))

            let linked = tmpDir("Linked")
            try await client.worktreeAdd(path: linked, branch: "feature")
            let fromWorktree = try await LocalStore.open(GitClient(workingDirectory: linked))
            #expect(canonicalPath(fromWorktree.storageDirectory) == canonicalPath(relative.storageDirectory))

            let elsewhere = tmpDir("LocalStoreElsewhere")
            try await client.configSet("lfs.storage", elsewhere.path)
            let absolute = try await LocalStore.open(client)
            #expect(absolute.storageDirectory.path == elsewhere.path)
            #expect(absolute.objectPathname(Self.oid).path == elsewhere.path + "/objects/58/91/\(Self.oid)")
        }
    }

    @Test("an object is written through tmp, verified, and renamed into objects/")
    func storesVerifiedObject() async throws {
        try await host.run {
            let repo = try await makeRepo()
            let store = try await LocalStore.open(GitClient(workingDirectory: repo))
            #expect(try await !store.objectExists(Self.oid, size: 6))

            let path = try await store.store(Self.content, oid: Self.oid)
            #expect(canonicalPath(path) == canonicalPath(store.objectPathname(Self.oid)))
            #expect(try Data(contentsOf: path) == Self.content)
            #expect(try await store.objectExists(Self.oid, size: 6))
            #expect(try await !store.objectExists(Self.oid, size: 7))
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.temporaryDirectory.path).isEmpty)
        }
    }

    @Test("storing an object that is already there keeps it")
    func storesExistingObject() async throws {
        try await host.run {
            let repo = try await makeRepo()
            let store = try await LocalStore.open(GitClient(workingDirectory: repo))
            try await store.store(Self.content, oid: Self.oid)
            let path = try await store.store(Self.content, oid: Self.oid)
            #expect(try Data(contentsOf: path) == Self.content)
            #expect(try await store.objectExists(Self.oid, size: 6))
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.temporaryDirectory.path).isEmpty)
        }
    }

    @Test("the empty object is the null device; its temp file is dropped")
    func storesEmptyObject() async throws {
        try await host.run {
            let repo = try await makeRepo()
            let store = try await LocalStore.open(GitClient(workingDirectory: repo))
            let path = try await store.store(Data(), oid: Pointer.emptyObjectSHA256)
            #expect(path == LocalStore.nullDevice)
            #expect(try FileManager.default.contentsOfDirectory(atPath: store.temporaryDirectory.path).isEmpty)
        }
    }

    @Test("a directory in the object's place is a failure, not a stored object")
    func directoryInObjectsPlace() async throws {
        try await host.run {
            let repo = try await makeRepo()
            let store = try await LocalStore.open(GitClient(workingDirectory: repo))
            let blocker = store.objectPathname(Self.oid).appendingPathComponent("child")
            try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
            await #expect(throws: LocalStoreError.self) {
                try await store.store(Self.content, oid: Self.oid)
            }
            #expect(try await !store.objectExists(Self.oid, size: 6))
        }
    }

    @Test("temporary files never share a name")
    func temporaryFilesAreExclusive() async throws {
        try await host.run {
            let store = LocalStore(gitStorageDirectory: tmpDir("LocalStoreTemp"))
            var names = Set<String>()
            for _ in 0..<50 {
                names.insert(try await store.makeTemporaryFile().lastPathComponent)
            }
            #expect(names.count == 50)
        }
    }

    @Test("the embedded client reads the isolated global config, not the developer's")
    func isolatedGlobalConfig() async throws {
        let shared = tmpDir("LocalStoreGlobal")
        try "[lfs]\n\tstorage = \(shared.path)\n".write(to: host.globalConfig, atomically: true, encoding: .utf8)
        try await host.run {
            let repo = try await makeRepo()
            let store = try await LocalStore.open(GitClient(workingDirectory: repo))
            #expect(store.storageDirectory.path == shared.path)
        }
    }

    @Test("a corrupt temp object is rejected and never moved into objects/")
    func rejectsCorruptObject() async throws {
        try await host.run {
            let repo = try await makeRepo()
            let store = try await LocalStore.open(GitClient(workingDirectory: repo))
            let temporary = try await store.makeTemporaryFile()
            #expect(canonicalPath(temporary.deletingLastPathComponent()) == canonicalPath(store.temporaryDirectory))
            try Data("hellO\n".utf8).write(to: temporary)

            let (actual, _) = try LocalStore.sha256(of: temporary)
            await #expect {
                try await store.insert(temporaryFile: temporary, oid: Self.oid)
            } throws: { error in
                String(describing: error) == "expected OID \(Self.oid), got \(actual) after 6 bytes written"
            }
            #expect(!FileManager.default.fileExists(atPath: store.objectPathname(Self.oid).path))
            #expect(try await !store.objectExists(Self.oid, size: 6))
            #expect(FileManager.default.fileExists(atPath: temporary.path))
        }
    }

    @Test("the verify failure is worded as git-lfs words it")
    func verifyFailureText() {
        let error = LocalStoreError.unexpectedOID(expected: Self.oid, actual: Pointer.emptyObjectSHA256, written: 0)
        #expect(String(describing: error)
                == "expected OID \(Self.oid), got \(Pointer.emptyObjectSHA256) after 0 bytes written")
        #expect(String(describing: LocalStoreError.tooShortObjectID("abc")) == "too short object ID: \"abc\"")
    }

    @Test("an object ID under four characters has no path")
    func tooShortObjectID() async throws {
        try await host.run {
            let store = LocalStore(gitStorageDirectory: tmpDir("LocalStoreShort"))
            await #expect(throws: LocalStoreError.tooShortObjectID("abc")) {
                try await store.objectPath("abc")
            }
        }
    }
}
