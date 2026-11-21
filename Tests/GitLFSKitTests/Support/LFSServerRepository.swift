import CGitKit
import Crypto
import Foundation
import GitLFSTestSupport
@testable import GitLFSKit
@testable import SwiftGit

/// A throwaway repository whose `lfs.url` is an ``LFSTestServer``, for the
/// fetch and upload suites. Files are committed as LFS pointers.
struct LFSServerRepository {
    let directory: URL
    let git: GitClient
    let client: LFSClient
    let store: LocalStore

    static func oid(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `config` is in place before the client reads it.
    static func run(
        _ server: LFSTestServer, config: [(String, String)] = [], credentials: CredentialProvider? = nil,
        _ body: (LFSServerRepository) async throws -> Void
    ) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let remote = host.root.appendingPathComponent("remote.git")
            try await GitClient(workingDirectory: remote).initRepository(bare: true)
            let made = try await LFSFixture.make(
                host, "server", remotes: [("origin", remote.path)],
                config: [("lfs.url", server.endpoint.absoluteString), ("lfs.locksverify", "false")] + config)
            let client = await LFSClient(git: made.client, credentials: credentials, configuration: .ephemeral)
            let repository = LFSServerRepository(
                directory: made.directory, git: made.client, client: client,
                store: LocalStore(gitStorageDirectory: made.directory.appendingPathComponent(".git")))
            try await body(repository)
        }
    }

    /// Writes each file as the pointer to its contents and commits them all.
    @discardableResult
    func commit(_ files: [(path: String, contents: Data)], message: String = "pointers") async throws -> String {
        for file in files {
            let url = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pointer = Pointer(oid: Self.oid(file.contents), size: Int64(file.contents.count))
            try Data(pointer.encoded.utf8).write(to: url)
        }
        try await git.add(paths: [])
        return try await git.commit(message: message, author: nil, allowEmpty: false)
    }

    /// ``LFSClient/fetch(refs:remote:include:exclude:all:dryRun:json:terminal:git:)``,
    /// with the progress text it streams to stdout placed before the result's
    /// own stdout, which is the order a shell sees them in.
    func fetch(
        refs: [String] = [], include: String? = nil, exclude: String? = nil, all: Bool = false,
        dryRun: Bool = false, json: Bool = false, terminal: Bool = false, git: GitClient
    ) async throws -> LFSCommandResult {
        let streamed = TransferTestLock("")
        var environment = LFSTransferEnvironment()
        environment.stdout = { text in streamed.withLock { $0 += text } }
        var result = try await client.fetch(
            refs: refs, remote: "", include: include, exclude: exclude, all: all, dryRun: dryRun,
            json: json, terminal: terminal, git: git, environment: environment)
        result.stdout = streamed.withLock { $0 } + result.stdout
        return result
    }

    /// ``LFSClient/uploadObjects(for:remote:remoteBranches:dryRun:terminal:git:)``,
    /// with streamed progress as in ``fetch(refs:include:exclude:all:dryRun:json:terminal:git:)``.
    func uploadObjects(
        for updates: [LFSRefUpdate], remoteBranches: [String]? = nil, dryRun: Bool = false, git: GitClient
    ) async throws -> LFSCommandResult {
        let streamed = TransferTestLock("")
        var environment = LFSTransferEnvironment()
        environment.stdout = { text in streamed.withLock { $0 += text } }
        var result = try await client.uploadObjects(
            for: updates, remote: "", remoteBranches: remoteBranches, dryRun: dryRun, terminal: false,
            git: git, environment: environment)
        result.stdout = streamed.withLock { $0 } + result.stdout
        return result
    }

    /// Puts `contents` in the local object store.
    func storeLocally(_ contents: Data) async throws {
        try contents.write(to: try await store.objectPath(Self.oid(contents)))
    }

    func hasLocally(_ contents: Data) -> Bool {
        FileManager.default.fileExists(atPath: store.objectPathname(Self.oid(contents)).path)
    }

    /// Points `name` at `commit`, as a fetch would leave a remote-tracking ref.
    func setReference(_ name: String, to commit: String) async throws {
        try await git.withRepository { repository in
            guard let repo = GitClient.handle(of: repository) else { return }
            var target = git_oid()
            _ = git_oid_fromstr(&target, commit)
            var reference: OpaquePointer?
            _ = git_reference_create(&reference, repo, name, &target, 1, nil)
            git_reference_free(reference)
        }
    }
}
