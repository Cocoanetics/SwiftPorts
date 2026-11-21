#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import SwiftGit

extension GitClientDiffIndexRefreshTests {
    @Test("stat-only refresh does not revalidate an indexed missing object")
    func refreshMissingIndexedBlob() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("new.txt")
        try Data("ordinary file".utf8).write(to: path)
        try runGit(["add", "new.txt"], in: dir)
        let oid = try runGit(["rev-parse", ":new.txt"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
        let object = dir.appendingPathComponent(".git/objects/\(oid.prefix(2))/\(oid.dropFirst(2))")
        try FileManager.default.removeItem(at: object)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: path.path)
        let client = GitClient(workingDirectory: dir)
        let entries = try await client.diffIndex(cached: false, refresh: true)
        #expect(try parse(refreshedDiff(in: dir)) == entries)
        let added = try #require(entries.first { $0.destinationPath == "new.txt" })
        #expect(added.newOID == oid)
        #expect(try await client.diffIndex(cached: false, refresh: true) == entries)
    }
}
#endif
