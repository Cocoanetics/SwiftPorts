import Foundation
import ShellKit
import SwiftGit
import Testing
@testable import GitLFSKit

extension LFSTransferQueueTests {
    private var lockedPage: Data {
        Data(#"{"ours":[],"theirs":[{"path":"file.bin","owner":{"name":"Alice"}}]}"#.utf8)
    }

    private func lockCommand(
        _ client: LFSClient, store: LocalStore, directory: URL,
        prePush: Bool = false, plain: Bool = false, dryRun: Bool = false, extra: Bool = false
    ) async throws -> LFSCommandResult {
        let git = GitClient(workingDirectory: directory)
        // A local Git remote keeps the advertisement independent of the mocked LFS HTTP endpoint.
        try await git.configSet("remote.origin.url", directory.path)
        try await git.configSet("user.name", "Test")
        try await git.configSet("user.email", "test@example.com")
        let contents = plain ? data : Data(Pointer(oid: oid, size: Int64(data.count)).encoded.utf8)
        try contents.write(to: directory.appendingPathComponent("file.bin"))
        try data.write(to: try await store.objectPath(oid))
        if extra {
            let bytes = Data("unlocked\n".utf8)
            let pointer = Pointer(oid: hash(bytes), size: Int64(bytes.count))
            try Data(pointer.encoded.utf8).write(to: directory.appendingPathComponent("free.bin"))
            try bytes.write(to: try await store.objectPath(pointer.oid))
        }
        try await git.add(paths: [])
        let tip = try await git.commit(message: "locked file", author: nil, allowEmpty: false)
        if prePush {
            let line = "refs/heads/main \(tip) refs/heads/main \(String(repeating: "0", count: 40))\n"
            let shell = Shell(stdin: .data(Data(line.utf8)), environment: Shell.current.environment)
            shell.sandbox = Shell.current.sandbox
            return try await shell.withCurrent {
                var options = PrePushOptions()
                options.dryRun = dryRun
                return try await options.run(["origin", "url"], client: client, git: git)
            }
        }
        var options = PushOptions()
        options.dryRun = dryRun
        return try await options.run(["origin", "HEAD"], client: client, git: git)
    }

    @Test("push and pre-push reject another user's locked LFS file before uploading", arguments: [false, true])
    func commandLocks(prePush: Bool) async throws {
        LFSTransferURLProtocol.install { request in
            #expect(request.url?.path == "/lfs/locks/verify")
            let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            #expect((body?["ref"] as? [String: String])?["name"] == "refs/heads/main")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == LFSMediaType.requestContentType)
            return LFSTransferReply(body: lockedPage)
        }
        try await run(config: [("lfs.url", "https://example.com/lfs"), ("lfs.locksverify", "true")]) {
            client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory, prePush: prePush)
            #expect(result.status == 2 && result.stderr == "Cannot update locked files.\n")
            #expect(result.stdout == "Unable to push locked files:\n* file.bin - Alice (refs: main)\n")
            #expect(LFSTransferURLProtocol.requests.count == 1)
        }
    }

    @Test("non-LFS blobs are checked for locks, including in dry runs", arguments: [false, true])
    func plainFileLocks(dryRun: Bool) async throws {
        LFSTransferURLProtocol.install { _ in LFSTransferReply(body: lockedPage) }
        try await run(config: [("lfs.url", "https://example.com/lfs"), ("lfs.locksverify", "true")]) {
            client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory,
                                               plain: true, dryRun: dryRun)
            #expect(result.status == 2 && result.stderr == "Cannot update locked files.\n")
            #expect(result.stdout.contains("file.bin - Alice"))
            #expect(LFSTransferURLProtocol.requests.count == 1)
        }
    }

    @Test("explicitly disabled verification bypasses the API and unknown state only warns", arguments: [false, true])
    func advisoryLocks(disabled: Bool) async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.path.hasSuffix("/locks/verify") == true { return LFSTransferReply(body: lockedPage) }
            if request.url?.lastPathComponent == "batch" { return .batch(request, operation: "upload") }
            return LFSTransferReply()
        }
        let config = [("lfs.url", "https://example.com/lfs")] + (disabled ? [("lfs.locksverify", "false")] : [])
        try await run(config: config) { client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory)
            #expect(result.status == 0)
            #expect(LFSTransferURLProtocol.requests.contains { $0.httpMethod == "PUT" })
            if disabled {
                #expect(result.stdout.isEmpty && result.stderr.isEmpty)
                #expect(!LFSTransferURLProtocol.requests.contains { $0.url?.path.hasSuffix("/locks/verify") == true })
            } else {
                #expect(result.stdout.contains("Unable to push locked files:"))
                #expect(result.stderr.hasPrefix("Locking support detected on remote \"origin\"."))
                #expect(result.stderr.hasSuffix("warning: The above files would have halted this push.\n"))
            }
        }
    }

    @Test("verification follows the server's pagination cursor")
    func paginatedLocks() async throws {
        LFSTransferURLProtocol.install { request in
            let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            if body?["cursor"] as? String == "page2" { return LFSTransferReply(body: lockedPage) }
            return LFSTransferReply(body: Data(#"{"ours":[],"theirs":[],"next_cursor":"page2"}"#.utf8))
        }
        try await run(config: [("lfs.url", "https://example.com/lfs"), ("lfs.locksverify", "true")]) {
            client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory)
            #expect(result.status == 2 && LFSTransferURLProtocol.requests.count == 2)
        }
    }

    @Test("unsupported lock APIs disable verification locally", arguments: [404, 501])
    func unsupportedLocks(status: Int) async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.path.hasSuffix("/locks/verify") == true {
                return LFSTransferReply(status: status, body: Data(#"{"message":"not supported"}"#.utf8))
            }
            if request.url?.lastPathComponent == "batch" { return .batch(request, operation: "upload") }
            return LFSTransferReply()
        }
        try await run(config: [("lfs.url", "https://example.com/lfs"), ("lfs.locksverify", "true")]) {
            client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory)
            #expect(result.status == 0 && result.stderr.isEmpty)
            let git = GitClient(workingDirectory: directory)
            #expect(try await git.configGet("lfs.https://example.com/lfs.locksverify", scope: .local) == "false")
            #expect(LFSTransferURLProtocol.requests.contains { $0.httpMethod == "PUT" })
        }
    }

    @Test("enabled verification fails closed on authentication or server errors", arguments: [403, 500])
    func failedLockVerification(status: Int) async throws {
        LFSTransferURLProtocol.install { _ in
            LFSTransferReply(status: status, body: Data(#"{"message":"verification refused"}"#.utf8))
        }
        try await run(config: [("lfs.url", "https://example.com/lfs"), ("lfs.locksverify", "true")]) {
            client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory)
            #expect(result.status == 2 && result.stdout.isEmpty)
            #expect(LFSTransferURLProtocol.requests.count == 1)
            #expect(result.stderr.contains(status == 403 ? "error: Authentication error:" : "does not support"))
        }
    }

    @Test("GitHub enables lock verification by default")
    func knownLockingHost() async throws {
        LFSTransferURLProtocol.install { _ in LFSTransferReply(body: lockedPage) }
        try await run(config: [("lfs.url", "https://github.com/example/repo.git/info/lfs")]) {
            client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory)
            #expect(result.status == 2 && result.stderr == "Cannot update locked files.\n")
            #expect(LFSTransferURLProtocol.requests.count == 1)
        }
    }

    @Test("unlocked objects still transfer while a locked file rejects the push")
    func mixedLockedFiles() async throws {
        let freeOID = hash(Data("unlocked\n".utf8))
        LFSTransferURLProtocol.install { request in
            if request.url?.path.hasSuffix("/locks/verify") == true { return LFSTransferReply(body: lockedPage) }
            if request.url?.lastPathComponent == "batch" { return .batch(request, operation: "upload") }
            #expect(request.url?.lastPathComponent == freeOID)
            return LFSTransferReply()
        }
        try await run(config: [("lfs.url", "https://example.com/lfs"), ("lfs.locksverify", "true")]) {
            client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory, extra: true)
            #expect(result.status == 2 && result.stderr == "Cannot update locked files.\n")
            let puts = LFSTransferURLProtocol.requests.filter { $0.httpMethod == "PUT" }
            #expect(puts.count == 1 && puts.first?.url?.lastPathComponent == freeOID)
        }
    }

    @Test("our own locks allow uploads and print an unlock reminder")
    func ownedLocks() async throws {
        LFSTransferURLProtocol.install { request in
            if request.url?.path.hasSuffix("/locks/verify") == true {
                let page = #"{"ours":[{"path":"file.bin","owner":{"name":"Test"}}],"theirs":[]}"#
                return LFSTransferReply(body: Data(page.utf8))
            }
            if request.url?.lastPathComponent == "batch" { return .batch(request, operation: "upload") }
            return LFSTransferReply()
        }
        try await run(config: [("lfs.url", "https://example.com/lfs"), ("lfs.locksverify", "true")]) {
            client, store, directory in
            let result = try await lockCommand(client, store: store, directory: directory)
            #expect(result.status == 0 && result.stderr.isEmpty)
            let expected = "Consider unlocking your own locked files: (`git lfs unlock <path>`)\n* file.bin\n"
            #expect(result.stdout == expected)
            #expect(LFSTransferURLProtocol.requests.contains { $0.httpMethod == "PUT" })
        }
    }
}
