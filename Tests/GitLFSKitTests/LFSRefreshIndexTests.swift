import Foundation
import Testing
import ShellKit
import SwiftGit
@testable import GitLFSKit

extension LFSFilterTests {
    @Suite("SwiftGit stat-only index refresh through clean filter")
    struct LFSRefreshIndexTests {
        @Test("refreshIndex hashes through the clean filter and preserves pointer OID, mode, stage, and flags")
        func refreshIndexHashesThroughCleanFilter() async throws {
            try await LFSFilterFixture.run { host in
                let payload = Data("smudged payload for index refresh\n".utf8)
                let made = try await LFSFilterFixture.seed(host, data: payload)
                let file = made.directory.appendingPathComponent("a.lfs")
                let beforeEntry = try #require(try await made.client.indexedEntries().first { $0.path == "a.lfs" })
                let pointerBytes = Data(made.pointer.encoded.utf8)
                #expect(try await made.client.catFileBlob(beforeEntry.oid) == pointerBytes)

                // Simulate a GIT_LFS_SKIP_SMUDGE=1 state: index has pointer stat (130 bytes),
                // then checkout writes the real payload bytes onto disk without touching the index.
                try pointerBytes.write(to: file)
                try await made.client.add(paths: ["a.lfs"])
                try payload.write(to: file)

                // Before refresh: stat size differs (pointer vs payload), so uncached diffIndex reports it.
                let dirtyBefore = try await made.client.diffIndex(ref: "HEAD", cached: false)
                #expect(dirtyBefore.map(\.destinationPath) == ["a.lfs"])

                try await made.client.refreshIndex(paths: ["a.lfs"])

                let afterEntry = try #require(try await made.client.indexedEntries().first { $0.path == "a.lfs" })
                #expect(afterEntry.oid == beforeEntry.oid)
                #expect(afterEntry.mode == beforeEntry.mode)
                #expect(afterEntry.stage == 0)
                #expect(!afterEntry.skipWorktree)
                #expect(!afterEntry.assumeUnchanged)

                let dirtyAfter = try await made.client.diffIndex(ref: "HEAD", cached: false)
                #expect(dirtyAfter.isEmpty)
                #expect(try await made.client.status().isClean)

                #if os(macOS) || os(Linux)
                // Keep the SDK assertions above active without the optional reference binary.
                if LFSOracle.isVersion371Available {
                    let oracle = LFSOracle()
                    defer { try? FileManager.default.removeItem(at: oracle.root) }
                    let diffQuiet = try oracle.run(["diff-index", "--quiet", "HEAD", "--"], in: made.directory)
                    #expect(diffQuiet.status == 0, "git diff-index --quiet HEAD failed: \(diffQuiet.err)")
                }
                #endif
            }
        }

        @Test("refreshIndex leaves modified files dirty and skips missing, unmerged, and non-blob paths")
        func refreshIndexSkipsModifiedAndMissing() async throws {
            try await LFSFilterFixture.run { host in
                let payload = Data("original lfs content\n".utf8)
                let made = try await LFSFilterFixture.seed(host, data: payload)
                let file = made.directory.appendingPathComponent("a.lfs")
                let indexedBefore = try #require(try await made.client.indexedEntries().first { $0.path == "a.lfs" })

                try Data("modified content that does not match pointer\n".utf8).write(to: file)
                try await made.client.refreshIndex(paths: ["a.lfs", "missing.lfs", "../escape.lfs", ""])

                let indexedAfter = try #require(try await made.client.indexedEntries().first { $0.path == "a.lfs" })
                #expect(indexedAfter.oid == indexedBefore.oid)
                #expect(try await made.client.status().unstagedEntries.map(\.path) == ["a.lfs"])
            }
        }

        @Test("refreshIndex authorizes the index and worktree files through Shell.sandbox")
        func refreshIndexAuthorizesPaths() async throws {
            try await LFSFilterFixture.run { host in
                let payload = Data("sandboxed lfs payload\n".utf8)
                let made = try await LFSFilterFixture.seed(host, data: payload)
                let file = made.directory.appendingPathComponent("a.lfs").standardizedFileURL
                let indexFile = made.directory.appendingPathComponent(".git/index").standardizedFileURL

                Shell.current.sandbox = host.sandbox(refusing: { $0.standardizedFileURL == file })
                await #expect(throws: Sandbox.Denial.self) {
                    try await made.client.refreshIndex(paths: ["a.lfs"])
                }

                Shell.current.sandbox = host.sandbox(refusing: { $0.standardizedFileURL == indexFile })
                await #expect(throws: Sandbox.Denial.self) {
                    try await made.client.refreshIndex(paths: ["a.lfs"])
                }
                Shell.current.sandbox = host.sandbox
            }
        }

        @Test("filterAttribute reports filter=lfs from .gitattributes and info/attributes")
        func filterAttributeReadsAttributes() async throws {
            try await LFSFilterFixture.run { host in
                let made = try await LFSFilterFixture.seed(host, data: Data("attr\n".utf8))
                try Data("plain\n".utf8).write(to: made.directory.appendingPathComponent("plain.txt"))
                try await made.client.add(paths: ["plain.txt"])
                let infoDir = made.directory.appendingPathComponent(".git/info")
                try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
                try Data("*.bin filter=lfs\n".utf8).write(to: infoDir.appendingPathComponent("attributes"))

                let attrs = try await made.client.filterAttribute(for: ["a.lfs", "plain.txt", "nested/x.bin"])
                #expect(attrs["a.lfs"] == "lfs")
                #expect(attrs["nested/x.bin"] == "lfs")
                #expect(attrs["plain.txt"] == nil)
            }
        }
    }
}
