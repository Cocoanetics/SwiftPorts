// A zero `file_size` is git's racily-clean smudge. Kept in its own file
// so the refresh suite can stay inside the file-length lint limit.
#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import SwiftGit

extension GitClientDiffIndexRefreshTests {
    @Test("a zero index size is a stat smudge, not a hashed work tree")
    func smudgedSize() async throws {
        let origin = try makeRepo()
        try Data("z".utf8).write(to: origin.appendingPathComponent("c.txt"))
        try runGit(["add", "c.txt"], in: origin)
        try runGit(["commit", "-m", "byte"], in: origin)
        for name in ["a.txt", "b.txt", "c.txt"] {
            let oid = try runGit(["rev-parse", ":\(name)"], in: origin)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try runGit(["update-index", "--cacheinfo", "100644,\(oid),\(name)"], in: origin)
        }
        try Data("y\n".utf8).write(to: origin.appendingPathComponent("b.txt"))
        let clientDir = try copyRepo(origin)
        let oracle = try copyRepo(origin)
        defer { [origin, clientDir, oracle].forEach { try? FileManager.default.removeItem(at: $0) } }
        let client = GitClient(workingDirectory: clientDir)
        let blobs = try runGit(["ls-files", "-s"], in: clientDir)

        let plain = try await client.diffIndex(ref: "HEAD", cached: false)
        #expect(try parse(gitDiffIndex(cached: false, ref: "HEAD", in: oracle)) == plain)
        #expect(plain.contains { $0.destinationPath == "a.txt" && $0.newOID == zeros })
        #expect(plain.contains { $0.destinationPath == "c.txt" && $0.newOID == zeros })

        let refreshed = try await client.diffIndex(ref: "HEAD", cached: false, refresh: true)
        #expect(try parse(refreshedDiff(in: oracle)) == refreshed)
        #expect(refreshed.contains { $0.destinationPath == "a.txt" } == false)
        #expect(refreshed.contains { $0.destinationPath == "c.txt" } == false)
        let edited = try #require(refreshed.first { $0.destinationPath == "b.txt" })
        #expect(edited.status == "M")
        #expect(edited.newOID == zeros)
        #expect(try runGit(["ls-files", "-s"], in: clientDir) == blobs)
        #expect(try await client.diffIndex(ref: "HEAD", cached: false) == refreshed)
    }
}
#endif
