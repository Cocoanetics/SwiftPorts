import Foundation
import Crypto
import Testing
import ShellKit
import SwiftGit
import GitLFSTestSupport
@testable import GitLFSKit

extension LFSFilterTests {
    @Suite("LFS checkout, clone and status integration", .timeLimit(.minutes(2)))
    struct LFSFilterIntegrationTests {
        @Test("failed stash restoration retains the unstaged edit and can be retried",
               arguments: ["pop", "branch"])
        func stashFailure(mode: String) async throws {
            try await LFSFilterFixture.run { host in
                let original = Data("original content\n".utf8)
                let edited = Data("unstaged edited content\n".utf8)
                let made = try await LFSFilterFixture.seed(host, data: original, config: [
                    ("filter.lfs.required", "false"), ("lfs.skipdownloaderrors", "false")
                ])
                let file = made.directory.appendingPathComponent("a.lfs")
                try edited.write(to: file)
                let stash = try await made.client.stashSave(message: "edit", author: nil)
                let editedPointer = Pointer(oid: LFSFilterFixture.hash(edited), size: Int64(edited.count))
                #expect(try await made.client.catFileBlob("\(stash):a.lfs") == Data(editedPointer.encoded.utf8))
                let indexed = try #require(try await made.client.indexedEntries().first { $0.path == "a.lfs" })
                #expect(try await made.client.catFileBlob(indexed.oid) == Data(made.pointer.encoded.utf8))
                #expect(try Data(contentsOf: file) == original)
                let store = try await LocalStore.open(made.client)
                let object = store.objectPathname(editedPointer.oid)
                // Deny just this cached object, without relying on OS permission
                // bits (which elevated test runners can bypass).
                Shell.current.sandbox = host.sandbox(refusing: { $0 == object })
                await #expect(throws: GitFilterError.self) {
                    if mode == "pop" { try await made.client.stashPop(index: 0) }
                    else { try await made.client.stashBranch(name: "recovered") }
                }
                Shell.current.sandbox = host.sandbox
                let entries = try await made.client.stashList()
                #expect(entries.map(\.sha) == [stash])
                #expect(try await made.client.indexedEntries().first { $0.path == "a.lfs" }?.oid == indexed.oid)
                _ = try #require(entries.first)
                // Reset any partial checkout, restore access and retry the
                // retained entry: the original unstaged bytes must be recoverable.
                try await made.client.checkoutPaths(["a.lfs"])
                try await made.client.stashPop(index: 0)
                #expect(try Data(contentsOf: file) == edited)
                #expect(try await made.client.stashList().isEmpty)
                #expect(try await made.client.indexedEntries().first { $0.path == "a.lfs" }?.oid == indexed.oid)
            }
        }

        @Test("optional process failure finishes other paths and does not leak into later operations",
               arguments: [false, true])
        func mixedPathFailure(statusFirst: Bool) async throws {
            try await LFSTestServer.withServer { server in
                try await LFSFilterFixture.run { host in
                    let data = Data("missing object\n".utf8)
                    let made = try await LFSFilterFixture.seed(host, data: data, config: [
                        ("lfs.url", server.endpoint.absoluteString), ("filter.lfs.required", "false"),
                        ("lfs.skipdownloaderrors", "false")
                    ])
                    let ordinary = Data("ordinary tracked content\n".utf8)
                    let file = made.directory.appendingPathComponent("z.txt")
                    try ordinary.write(to: file)
                    try await made.client.add(paths: ["z.txt"])
                    _ = try await made.client.commit(message: "ordinary", author: nil, allowEmpty: false)
                    let store = try await LocalStore.open(made.client)
                    try FileManager.default.removeItem(at: store.objectPathname(made.pointer.oid))
                    try FileManager.default.removeItem(at: made.directory.appendingPathComponent("a.lfs"))
                    try FileManager.default.removeItem(at: file)
                    server.inject(.objectStatus(oid: made.pointer.oid, code: 404))
                    await #expect(throws: LFSFilterFailure.self) {
                        try await made.client.checkoutPaths(["a.lfs", "z.txt"])
                    }
                    #expect(try Data(contentsOf: file) == ordinary)
                    #expect(try Data(contentsOf: made.directory.appendingPathComponent("a.lfs")).isEmpty)
                    // Inspect the untouched failed file, before deleting or
                    // restoring it can invalidate checkout's cached stat data.
                    if statusFirst {
                        #expect(try await made.client.status().unstagedEntries.map(\.path) == ["a.lfs"])
                    }
                    let diff = try await made.client.diff(.workdirVsIndex, paths: ["a.lfs"])
                    #expect(!diff.isEmpty)
                    let status = try await made.client.status()
                    #expect(!status.isClean)
                    #expect(status.unstagedEntries.map(\.path) == ["a.lfs"])
                    let indexed = try #require(try await made.client.indexedEntries().first { $0.path == "a.lfs" })
                    #expect(try await made.client.catFileBlob(indexed.oid) == Data(made.pointer.encoded.utf8))
                    server.store(data, oid: made.pointer.oid)
                    try await LFSFilterFixture.restore(made.client, directory: made.directory, expected: data)
                }
            }
        }

        @Test("local checkout and linked worktree share default or configured storage",
               arguments: ["", "shared-lfs"])
        func local(storage: String) async throws {
            try await LFSFilterFixture.run { host in
                let data = Data(repeating: 0x71, count: 200_003)
                let config = storage.isEmpty ? [] : [("lfs.storage", storage)]
                let made = try await LFSFilterFixture.seed(host, data: data, config: config)
                let stored = try await LocalStore.open(made.client)
                #expect(try Data(contentsOf: stored.objectPathname(made.pointer.oid)) == data)
                #expect(try await made.client.catFileBlob("HEAD:a.lfs") == Data(made.pointer.encoded.utf8))
                try await LFSFilterFixture.restore(made.client, directory: made.directory, expected: data)
                let linked = host.root.appendingPathComponent("linked")
                try await made.client.worktreeAdd(path: linked, branch: "linked")
                let client = SwiftGit.GitClient(workingDirectory: linked)
                let shared = try await LocalStore.open(client)
                #expect(shared.objectsDirectory.standardizedFileURL == stored.objectsDirectory.standardizedFileURL)
                #expect(try Data(contentsOf: linked.appendingPathComponent("a.lfs")) == data)
                #expect(try await client.status().isClean)
                try await LFSFilterFixture.restore(client, directory: linked, expected: data)

                LFSFilterFixture.configureClone([("lfs.storage", stored.storageDirectory.path)])
                let destination = host.root.appendingPathComponent("clone")
                try await SwiftGit.GitClient(workingDirectory: host.root)
                    .clone(url: made.directory, directory: destination)
                let clone = SwiftGit.GitClient(workingDirectory: destination)
                #expect(try Data(contentsOf: destination.appendingPathComponent("a.lfs")) == data)
                #expect(try await clone.status().isClean)

                // `git clone`'s route: the remote as typed, with the
                // filter and storage configured only by the environment.
                let remoteDestination = host.root.appendingPathComponent("remote-clone")
                try await SwiftGit.GitClient(workingDirectory: host.root)
                    .clone(remote: made.directory.path, directory: remoteDestination)
                let remoteClone = SwiftGit.GitClient(workingDirectory: remoteDestination)
                #expect(try Data(contentsOf: remoteDestination.appendingPathComponent("a.lfs")) == data)
                #expect(try await remoteClone.status().isClean)
            }
        }

        @Test("checkout and clone download missing objects, including a 401 credential retry",
               arguments: [false, true])
        func server(authenticate: Bool) async throws {
            try await LFSTestServer.withServer { server in
                try await LFSFilterFixture.run { host in
                    let data = Data(repeating: 0x72, count: 200_003)
                    let made = try await LFSFilterFixture.seed(host, data: data,
                        config: [("lfs.url", server.endpoint.absoluteString)])
                    server.store(data, oid: made.pointer.oid)
                    let store = try await LocalStore.open(made.client)
                    try FileManager.default.removeItem(at: store.objectPathname(made.pointer.oid))
                    if authenticate { server.inject(.unauthorized) }
                    let client = SwiftGit.GitClient(workingDirectory: made.directory, credentials: { _, _, _ in
                        .userPassword(username: "filter", password: "secret")
                    })
                    try await LFSFilterFixture.restore(client, directory: made.directory, expected: data)
                    if authenticate {
                        #expect(server.requests().contains { $0.status == 401 })
                        #expect(server.requests().contains {
                            $0.requestHeaders["authorization"] == "Basic ZmlsdGVyOnNlY3JldA=="
                        })
                    }
                    LFSFilterFixture.configureClone([("lfs.url", server.endpoint.absoluteString)])
                    let destination = host.root.appendingPathComponent("clone")
                    try await SwiftGit.GitClient(workingDirectory: host.root)
                        .clone(url: made.directory, directory: destination)
                    let clone = SwiftGit.GitClient(workingDirectory: destination)
                    #expect(try Data(contentsOf: destination.appendingPathComponent("a.lfs")) == data)
                    #expect(try await clone.status().isClean)
                    #expect(server.requests().filter { $0.method == "GET" && $0.status == 200 }.count == 2)
                }
            }
        }

        @Test("64 MiB is generated, cleaned, staged and smudged with bounded stream buffers")
        func boundedMemory() async throws {
            try await LFSFilterFixture.run { host in
                let made = try await LFSFixture.make(host, "large", config: LFSFilterFixture.commands)
                try Data("*.lfs filter=lfs -text\n".utf8)
                    .write(to: made.directory.appendingPathComponent(".gitattributes"))
                let client = await LFSClient(git: made.client)
                let store = try await LocalStore.open(made.client)
                let context = LFSFilterContext(client: client, store: store, required: true,
                    skipSmudge: false, shell: Shell.current, remotes: LFSFilterRemotes())
                let file = made.directory.appendingPathComponent("a.lfs")
                #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
                let writer = try FileHandle(forWritingTo: file)
                defer { try? writer.close() }
                var hasher = SHA256()
                var pointerBytes = Data()
                var largestWrite = 0
                let stream = LFSCleanStream(context: context, fileWrite: { handle, bytes in
                    largestWrite = max(largestWrite, bytes.count)
                    try handle.write(contentsOf: bytes)
                }, output: { pointerBytes.append(contentsOf: $0) })
                // Only one 64 KiB block is alive per iteration; never materialize the file in Data.
                for index in 0..<1024 {
                    let block = Data(repeating: UInt8(index % 251), count: 64 * 1024)
                    hasher.update(data: block)
                    try writer.write(contentsOf: block)
                    try block.withUnsafeBytes(stream.write)
                    #expect(pointerBytes.isEmpty)
                    #expect(stream.bufferedByteCount <= Pointer.blobSizeCutoff)
                }
                try writer.close()
                try stream.close()
                let oid = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                let pointer = Pointer(oid: oid, size: 64 * 1024 * 1024)
                #expect(pointerBytes == Data(pointer.encoded.utf8))
                #expect(largestWrite <= 64 * 1024)
                try await made.client.add(paths: [".gitattributes", "a.lfs"])
                let entry = try #require(try await made.client.indexedEntries().first { $0.path == "a.lfs" })
                #expect(try await made.client.catFileBlob(entry.oid) == pointerBytes)
                var outputHash = SHA256()
                var outputCount = 0
                let smudge = LFSSmudgeStream(context: context, path: "a.lfs") {
                    #expect($0.count <= 64 * 1024)
                    outputCount += $0.count
                    outputHash.update(bufferPointer: $0)
                }
                try pointerBytes.withUnsafeBytes(smudge.write)
                #expect(smudge.bufferedByteCount <= Pointer.blobSizeCutoff)
                try smudge.close()
                #expect(outputCount == Int(pointer.size))
                #expect(outputHash.finalize().map { String(format: "%02x", $0) }.joined() == oid)
            }
        }

        @Test("cancelling a clean task removes its partial temporary file")
        func cancellationCleanup() async throws {
            try await LFSStreamFixture.run { (context, _, _) async throws in
                let ready = LFSTransferSignal()
                let task = Task {
                    let stream = LFSCleanStream(context: context) { _ in
                        Issue.record("cancelled transform must not emit a pointer")
                    }
                    try Data(repeating: 0x73, count: 128 * 1024).withUnsafeBytes(stream.write)
                    await ready.signal()
                    try await Task.sleep(for: .seconds(30))
                    try stream.close()
                }
                await ready.wait()
                #expect(try FileManager.default.contentsOfDirectory(atPath:
                    context.store.temporaryDirectory.path).count == 1)
                task.cancel()
                await #expect(throws: CancellationError.self) { try await task.value }
                #expect(try FileManager.default.contentsOfDirectory(atPath:
                    context.store.temporaryDirectory.path).isEmpty)
            }
        }

        #if os(macOS) || os(Linux)
        @Test("built git installs the filter at startup in concurrent isolated shells")
        func startup() async throws {
            let executable = try LFSFilterProcess.builtGit()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for token in ["first", "second"] {
                    group.addTask {
                        let host = IsolatedLFSHost()
                        defer { try? FileManager.default.removeItem(at: host.root) }
                        let directory = host.root.appendingPathComponent("repo")
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        func run(_ arguments: [String]) throws -> String {
                            let result = try LFSFilterProcess.run(executable, arguments, host: host, cwd: directory)
                            #expect(result.status == 0, "\(arguments): \(result.stderr)")
                            return result.stdout
                        }
                        _ = try run(["init", "-b", "main"])
                        for (key, value) in LFSFilterFixture.commands
                            + [("user.name", "Test"), ("user.email", "test@example.com")] {
                            _ = try run(["config", key, value])
                        }
                        let data = Data("isolated \(token) content\n".utf8)
                        try Data("*.lfs filter=lfs -text\n".utf8)
                            .write(to: directory.appendingPathComponent(".gitattributes"))
                        try data.write(to: directory.appendingPathComponent("a.lfs"))
                        _ = try run(["add", ".gitattributes", "a.lfs"])
                        let pointer = Pointer(oid: LFSFilterFixture.hash(data), size: Int64(data.count))
                        _ = try run(["commit", "-m", "startup"])
                        #expect(try run(["cat-file", "-p", "HEAD:a.lfs"]) == pointer.encoded)
                        try FileManager.default.removeItem(at: directory.appendingPathComponent("a.lfs"))
                        _ = try run(["checkout", "--", "a.lfs"])
                        #expect(try Data(contentsOf: directory.appendingPathComponent("a.lfs")) == data)
                        #expect(try run(["status", "--porcelain"]).isEmpty)
                    }
                }
                try await group.waitForAll()
            }
        }
        #endif
    }
}
