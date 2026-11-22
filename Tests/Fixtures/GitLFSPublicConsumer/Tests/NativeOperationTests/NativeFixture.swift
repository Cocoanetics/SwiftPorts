import Foundation
import GitKit
import GitLFSKit
import GitLFSTestSupport
import ShellKit
import Testing

struct NativeFixture: Sendable {
    let root: URL
    let shell: Shell
    static let bytes = Data("abc".utf8)
    static let pointer = Pointer(
        oid: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", size: 3)
    static let otherBytes = Data("hello".utf8)
    static let otherPointer = Pointer(
        oid: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", size: 5)
    static let signature = Signature(name: "Public consumer", email: "consumer@example.invalid")

    init(endpoint: URL) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("native-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("effective.config")
        try """
        [filter "lfs"]
            process = git-lfs filter-process
            clean = git-lfs clean -- %f
            smudge = git-lfs smudge -- %f
            required = true
        [lfs]
            url = \(endpoint.absoluteString)
            locksverify = false
        [lfs "\(endpoint.absoluteString)"]
            locksverify = false
        [user]
            name = Public consumer
            email = consumer@example.invalid
        """.write(to: config, atomically: true, encoding: .utf8)
        shell = Shell(environment: Environment(variables: [
            "HOME": root.path, "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
            "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "consumer.operation",
            "GIT_CONFIG_VALUE_0": "scoped"
        ], workingDirectory: root.path))
    }

    func path(_ name: String) -> URL { root.appendingPathComponent(name) }

    func sandbox(_ authorize: @escaping @Sendable (URL) async throws -> Void) -> Sandbox {
        Sandbox(documentsDirectory: root, downloadsDirectory: root, libraryDirectory: root,
                moviesDirectory: root, musicDirectory: root, picturesDirectory: root,
                sharedPublicDirectory: root, temporaryDirectory: root, trashDirectory: root,
                userDirectory: root, cachesDirectory: root, homeDirectory: root, authorize: authorize)
    }

    static func run(_ body: (NativeFixture, LFSTestServer) async throws -> Void) async throws {
        try await LFSTestServer.withServer { server in
            let fixture = try NativeFixture(endpoint: server.endpoint)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try GitLFSKit.installFilter()
            defer { try? GitLFSKit.uninstallFilter() }
            try await body(fixture, server)
        }
    }

    func seed(_ operation: GitLFSKit.Operation, name: String = "source") throws -> String {
        let directory = path(name)
        return try operation.createRepository(at: directory, using: {
            _ = try Repository.initialize(at: directory, initialBranch: "main")
        }, { repository in
            try Data("*.lfs filter=lfs -text\n".utf8).write(to: directory.appendingPathComponent(".gitattributes"))
            try Self.bytes.write(to: directory.appendingPathComponent("a.lfs"))
            try repository.add(paths: [])
            #expect(try repository.configGet("consumer.operation") == "scoped")
            let commit = try repository.commitDetailed(
                message: "content", author: Self.signature, allowEmpty: false, sign: .noSign)
            #expect(try repository.catFileBlob("HEAD:a.lfs") == Data(Self.pointer.encoded.utf8))
            return commit.sha
        })
    }

    func store(_ name: String = "source", storage: String? = nil) -> LocalStore {
        LocalStore(gitStorageDirectory: path(name).appendingPathComponent(".git"), storage: storage)
    }

    static func updates(_ updates: [PushUpdate]) -> [LFSRefUpdate] {
        updates.map { LFSRefUpdate(localRef: $0.localRef, localOID: $0.localOID,
                                  remoteRef: $0.remoteRef, remoteOID: $0.remoteOID) }
    }
}
