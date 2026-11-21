import Foundation
import Crypto
import Testing
import ShellKit
import SwiftGit
@testable import GitLFSKit

extension LFSFilterTests {
    @Suite("Streaming LFS clean")
    struct LFSCleanStreamTests {
        @Test("non-pointer content stores the object and emits pointer bytes")
        func regression() async throws {
            try await LFSStreamFixture.run { context, git, directory in
                try GitLFSKit.installFilter()
                defer { try? GitLFSKit.uninstallFilter() }
                try await git.configSet("filter.lfs.process", "git-lfs filter-process")
                try await git.configSet("filter.lfs.required", "true")
                let data = Data("non-pointer content\n".utf8)
                try Data("*.lfs filter=lfs -text\n".utf8)
                    .write(to: directory.appendingPathComponent(".gitattributes"))
                try data.write(to: directory.appendingPathComponent("a.lfs"))
                try await git.add(paths: [".gitattributes", "a.lfs"])
                let entry = try #require(try await git.indexedEntries().first { $0.path == "a.lfs" })
                let pointer = try Pointer.decode(try await git.catFileBlob(entry.oid))
                #expect(pointer.size == Int64(data.count))
                #expect(try Data(contentsOf: context.store.objectPathname(pointer.oid)) == data)
            }
        }

        @Test("chunk boundaries, cutoff, large content, duplicates and empty input",
               arguments: [0, 1, 1023, 1024, 1025, 2 * 1024 * 1024])
        func content(length: Int) async throws {
            try await LFSStreamFixture.run { context, _, _ in
                let data = Data(repeating: 0x61, count: length)
                for stride in [17, 1024, max(1, length)] {
                    var result = Data()
                    let stream = LFSCleanStream(context: context) { result.append(contentsOf: $0) }
                    for offset in Swift.stride(from: 0, to: length, by: stride) {
                        try data.subdata(in: offset..<min(offset + stride, length)).withUnsafeBytes(stream.write)
                        #expect(result.isEmpty)
                    }
                    try stream.close()
                    let expected = Pointer(oid: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                           size: Int64(length))
                    #expect(result == Data(expected.encoded.utf8))
                    if length > 0 {
                        #expect(try Data(contentsOf: context.store.objectPathname(expected.oid)) == data)
                    }
                    let files = (try? FileManager.default.contentsOfDirectory(atPath:
                        context.store.temporaryDirectory.path)) ?? []
                    #expect(files.isEmpty)
                }
            }
        }

        @Test("complete noncanonical pointers pass through, larger pointer prefixes do not")
        func pointers() async throws {
            try await LFSStreamFixture.run { context, _, _ in
                let pointer = Pointer(oid: String(repeating: "a", count: 64), size: 100)
                let noncanonical = Data((pointer.encoded.replacingOccurrences(of: "\n", with: "\r\n") + "\n").utf8)
                for data in [noncanonical, noncanonical + Data(repeating: 0x20, count: 2048)] {
                    var result = Data()
                    let stream = LFSCleanStream(context: context) { result.append(contentsOf: $0) }
                    try data.withUnsafeBytes(stream.write)
                    try stream.close()
                    if data.count < Pointer.blobSizeCutoff { #expect(result == data) }
                    else {
                        let cleaned = try Pointer.decode(result)
                        #expect(cleaned.size == Int64(data.count))
                        #expect(try Data(contentsOf: context.store.objectPathname(cleaned.oid)) == data)
                    }
                }
            }
        }

        @Test("optional insert failure replays original input; required failure emits nothing",
               arguments: [false, true])
        func insertFailure(required: Bool) async throws {
            try await LFSStreamFixture.run(required: required) { context, _, _ in
                try FileManager.default.createDirectory(at: context.store.storageDirectory,
                                                        withIntermediateDirectories: true)
                try Data("obstruct objects directory".utf8).write(to: context.store.objectsDirectory)
                let data = Data(repeating: 0x42, count: 300_000)
                var result = Data()
                var largest = 0
                let stream = LFSCleanStream(context: context) {
                    result.append(contentsOf: $0); largest = max(largest, $0.count)
                }
                try data.withUnsafeBytes(stream.write)
                if required {
                    #expect(throws: (any Error).self) { try stream.close() }
                    #expect(result.isEmpty)
                } else {
                    try stream.close()
                    #expect(result == data)
                    #expect(largest <= 64 * 1024)
                }
                #expect(try FileManager.default.contentsOfDirectory(atPath:
                    context.store.temporaryDirectory.path).isEmpty)
            }
        }

        @Test("output failures propagate for optional drivers")
        func outputFailure() async throws {
            try await LFSStreamFixture.run(required: false) { context, _, _ in
                var writes = 0
                let stream = LFSCleanStream(context: context) { _ in
                    writes += 1
                    throw CocoaError(.fileWriteUnknown)
                }
                try Data("content".utf8).withUnsafeBytes(stream.write)
                #expect(throws: CocoaError.self) { try stream.close() }
                #expect(writes == 1)
            }
        }

        @Test("partial writes and close failures replay optionally and always clean temporary files",
               arguments: ["first-write", "partial-write", "close"])
        func fileFailure(stage: String) async throws {
            for required in [false, true] {
                try await LFSStreamFixture.run(required: required) { context, _, _ in
                    let data = Data(repeating: 0x63, count: 200_000)
                    var result = Data()
                    var writes = 0
                    var stream: LFSCleanStream? = LFSCleanStream(context: context, fileWrite: { handle, bytes in
                        writes += 1
                        if stage == "first-write" || (stage == "partial-write" && writes == 3) {
                            try handle.write(contentsOf: bytes.prefix(bytes.count / 2))
                            throw CocoaError(.fileWriteOutOfSpace)
                        }
                        try handle.write(contentsOf: bytes)
                    }, fileClose: { handle in
                        try handle.close()
                        if stage == "close" { throw CocoaError(.fileWriteUnknown) }
                    }, output: { result.append(contentsOf: $0) })
                    do {
                        try data.withUnsafeBytes { try stream!.write($0) }
                        try stream!.close()
                        #expect(!required)
                        #expect(result == data)
                    } catch {
                        #expect(required)
                        #expect(result.isEmpty)
                    }
                    stream = nil
                    let files = try FileManager.default.contentsOfDirectory(atPath:
                        context.store.temporaryDirectory.path)
                    #expect(files.isEmpty)
                }
            }
        }

        @Test("temporary storage authorization fails closed or replays an optional driver",
               arguments: [false, true])
        func authorization(required: Bool) async throws {
            try await LFSStreamFixture.run(required: required, refusing: { $0.lastPathComponent == "tmp" }, {
                context, _, _ in
                let data = Data(repeating: 0x64, count: 100_000)
                var result = Data()
                let stream = LFSCleanStream(context: context) { result.append(contentsOf: $0) }
                if required {
                    #expect(throws: Sandbox.Denial.self) { try data.withUnsafeBytes(stream.write) }
                    #expect(result.isEmpty)
                } else {
                    try data.withUnsafeBytes(stream.write)
                    try stream.close()
                    #expect(result == data)
                }
                #expect(!FileManager.default.fileExists(atPath: context.store.temporaryDirectory.path))
            })
        }
    }
}
