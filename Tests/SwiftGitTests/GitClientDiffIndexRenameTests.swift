#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import SwiftGit

extension GitClientDiffIndexRefreshTests {
    @Test("rename detection hashes an unpaired dirty destination without storing it")
    func dirtyRenameDestination() async throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try runGit(["mv", "a.txt", "new.txt"], in: dir)
        try Data("entirely different worktree contents\n".utf8).write(to: dir.appendingPathComponent("new.txt"))
        let client = GitClient(workingDirectory: dir)
        for refresh in [false, true] {
            let entries = try await client.diffIndex(cached: false, refresh: refresh)
            let expected = try parse(gitDiffIndex(cached: false, ref: "HEAD", in: dir))
            #expect(entries == expected)
            let added = try #require(entries.first { $0.status == "A" })
            #expect(added.newOID != zeros)
            await #expect(throws: Libgit2Error.self) { try await client.catFileBlob(added.newOID) }
        }
    }
}
#endif
