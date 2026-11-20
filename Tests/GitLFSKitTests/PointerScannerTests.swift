import Foundation
import Testing
import Crypto
import CGitKit
import ShellKit
@testable import SwiftGit
@testable import GitLFSKit

@Suite("PointerScanner")
struct PointerScannerTests {
    private static let pointer = Pointer(oid: String(repeating: "a", count: 64), size: 123)
    private static let zero = String(repeating: "0", count: 40)

    private func withRepo(
        _ body: (IsolatedLFSHost, URL, GitClient) async throws -> Void
    ) async throws {
        let host = IsolatedLFSHost()
        defer { try? FileManager.default.removeItem(at: host.root) }
        try await host.run {
            let (dir, client) = try await LFSFixture.make(host, "pointer-scan")
            try await body(host, dir, client)
        }
    }

    private func blob(_ data: Data, client: GitClient) async throws -> String {
        try await client.withRepository { repository in
            let repo = try #require(GitClient.handle(of: repository))
            var oid = git_oid()
            let code = data.withUnsafeBytes {
                git_blob_create_from_buffer(&oid, repo, $0.baseAddress, $0.count)
            }
            #expect(code == 0)
            return String(cString: git_oid_tostr_s(&oid))
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("small pointers use the target SHA-256 and large blobs use all raw bytes")
    func smallPointerUsesTargetSHA256AndLargeBlobUsesRawBytes() async throws {
        try await withRepo { _, _, client in
            let scanner = PointerScanner(client: client)
            let small = Data(Self.pointer.encoded.utf8)
            let smallOID = try await blob(small, client: client)
            let pointer = try await scanner.scanBlob(smallOID)
            #expect(pointer == BlobScanResult(oid: smallOID, pointer: Self.pointer,
                                             contentsSHA256: Self.pointer.oid))
            #expect(pointer.contentsSHA256 != sha256(small))

            var large = small
            large.append(Data(repeating: 0xA5, count: 128 * 1024))
            large.append(Data([0x00, 0xFF, 0x80]))
            let largeOID = try await blob(large, client: client)
            let ordinary = try await scanner.scanBlob(largeOID)
            #expect(ordinary == BlobScanResult(oid: largeOID, pointer: nil,
                                              contentsSHA256: sha256(large)))
            #expect(ordinary.contentsSHA256.count == 64)
            #expect(try await scanner.readPointer(largeOID) == nil)
        }
    }

    @Test("pointer candidates must be strictly below the cutoff")
    func cutoffAndDecode() async throws {
        try await withRepo { _, _, client in
            let scanner = PointerScanner(client: client)
            for size in [1023, 1024, 1025] {
                var data = Data(Self.pointer.encoded.utf8)
                data.append(Data(repeating: 0x20, count: size - data.count))
                let oid = try await blob(data, client: client)
                let result = try await scanner.scanBlob(oid)
                if size < Pointer.blobSizeCutoff {
                    let decoded = try Pointer.decode(data)
                    #expect(decoded.canonical == false)
                    #expect(result.pointer == decoded)
                    #expect(result.contentsSHA256 == Self.pointer.oid)
                    #expect(try await scanner.readPointer(oid) == decoded)
                } else {
                    #expect(result.pointer == nil)
                    #expect(result.contentsSHA256 == sha256(data))
                    #expect(try await scanner.readPointer(oid) == nil)
                }
            }
            let empty = try await blob(Data(), client: client)
            #expect(try await scanner.readPointer(empty) == .empty)
            #expect(try await scanner.scanBlob(empty).contentsSHA256 == Pointer.emptyObjectSHA256)
        }
    }

    @Test("invalid pointers and ordinary binary blobs retain their raw content hash")
    func ordinaryAndMalformedBlobs() async throws {
        try await withRepo { _, dir, client in
            let scanner = PointerScanner(client: client)
            let malformed = PointerRejection.all.map { Data($0.text.utf8) }
            for data in malformed + [Data([0, 0xFF, 0x80, 10]), Data("hello\n".utf8)] {
                let oid = try await blob(data, client: client)
                #expect(try await scanner.readPointer(oid) == nil)
                #expect(try await scanner.scanBlob(oid)
                        == BlobScanResult(oid: oid, pointer: nil, contentsSHA256: sha256(data)))
                #expect(try await scanner.annotation(oid, name: "unused", repositoryRoot: dir)
                        == .git(sha256(data)))
            }
            let oid = try await blob(Data(Self.pointer.encoded.utf8), client: client)
            #expect(try await scanner.annotation(oid, name: "unused", repositoryRoot: dir)
                    == .lfs(Self.pointer.oid))
        }
    }

    @Test("only missing Git objects become missing annotations; corrupt blobs throw")
    func missingVersusCorruptObjects() async throws {
        try await withRepo { _, dir, client in
            let scanner = PointerScanner(client: client)
            let missing = String(repeating: "d", count: 40)
            #expect(try await scanner.annotation(missing, name: "unused", repositoryRoot: dir) == .missing)
            await #expect(throws: Libgit2Error.self) { try await scanner.readPointer(missing) }
            await #expect(throws: Libgit2Error.self) { try await scanner.scanBlob(missing) }

            let corrupt = try await blob(Data(repeating: 0x80, count: 4096), client: client)
            let object = dir.appendingPathComponent(".git/objects/\(corrupt.prefix(2))/\(corrupt.dropFirst(2))")
            var compressed = try Data(contentsOf: object)
            // Damage the zlib checksum while leaving its readable header intact.
            compressed[compressed.count - 1] ^= 0xFF
            try compressed.write(to: object, options: .atomic)
            #expect(try await scanner.readPointer(corrupt) == nil)
            await #expect(throws: Libgit2Error.self) { try await scanner.scanBlob(corrupt) }
            await #expect(throws: Libgit2Error.self) {
                try await scanner.annotation(corrupt, name: "unused", repositoryRoot: dir)
            }
            await #expect(throws: Libgit2Error.self) {
                try await scanner.annotation("invalid-oid", name: "unused", repositoryRoot: dir)
            }
        }
    }

    @Test("zero IDs stream the entire worktree file relative to the repository root")
    func fullWorktreeHash() async throws {
        try await withRepo { _, dir, client in
            let nested = dir.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let scanner = PointerScanner(client: client)
            var data = Data(Self.pointer.encoded.utf8)
            let path = nested.appendingPathComponent("file")
            try data.write(to: path)
            #expect(try await scanner.annotation(Self.zero, name: "nested/file", repositoryRoot: dir)
                    == .file(sha256(data)))

            data.append(Data(repeating: 0x80, count: 3 * 64 * 1024))
            data.append(Data("last bytes beyond streaming chunks".utf8))
            try data.write(to: path)
            // Shell cwd remains the host root, not the repository or nested directory.
            for zero in [Self.zero, String(repeating: "0", count: 64)] {
                #expect(try await scanner.annotation(zero, name: "nested/file", repositoryRoot: dir)
                        == .file(sha256(data)))
            }
        }
    }

    @Test("absent worktree paths and directories become deleted")
    func deletedPaths() async throws {
        try await withRepo { _, dir, client in
            let scanner = PointerScanner(client: client)
            #expect(try await scanner.annotation(Self.zero, name: "absent", repositoryRoot: dir) == .deleted)
            let directory = dir.appendingPathComponent("directory")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #expect(try await scanner.annotation(Self.zero, name: "directory", repositoryRoot: dir) == .deleted)
        }
    }

    @Test("sandbox failures propagate before inspecting worktree paths or Git objects")
    func sandboxFailures() async throws {
        try await withRepo { host, dir, client in
            let scanner = PointerScanner(client: client)
            let oid = try await blob(Data(Self.pointer.encoded.utf8), client: client)
            let file = dir.appendingPathComponent("blocked")
            let shell = Shell(environment: Environment(variables: host.variables, workingDirectory: host.root.path))
            shell.sandbox = host.sandbox(refusing: { $0.lastPathComponent == "blocked" })
            // A denied absent path must not turn into deleted, either.
            _ = await shell.withCurrent {
                await #expect(throws: Sandbox.Denial.self) {
                    try await scanner.annotation(Self.zero, name: "blocked", repositoryRoot: dir)
                }
            }
            try Data("secret".utf8).write(to: file)
            _ = await shell.withCurrent {
                await #expect(throws: Sandbox.Denial.self) {
                    try await scanner.annotation(Self.zero, name: "blocked", repositoryRoot: dir)
                }
            }
            shell.sandbox = host.sandbox(refusing: { $0.lastPathComponent == dir.lastPathComponent })
            _ = await shell.withCurrent {
                await #expect(throws: Sandbox.Denial.self) {
                    try await scanner.annotation(oid, name: "unused", repositoryRoot: dir)
                }
            }
        }
    }
}
