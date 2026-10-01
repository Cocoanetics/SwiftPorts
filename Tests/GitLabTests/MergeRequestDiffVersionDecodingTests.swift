import Foundation
import Testing
@testable import GitLab

struct MergeRequestDiffVersionDecodingTests {
    @Test func decodesVersionWithOmittedMetadata() throws {
        let json = Data("""
        [
          {
            "id": 110,
            "head_commit_sha": "33e2ee8579fda5bc36accc9c6fbd0b4fefda9e30",
            "base_commit_sha": "eeb57dffe83deb686a60a71c16c32f71046868fd",
            "start_commit_sha": "eeb57dffe83deb686a60a71c16c32f71046868fd"
          }
        ]
        """.utf8)

        let versions = try JSONDecoder.gitLab().decode(
            [MergeRequestDiffVersion].self,
            from: json)
        let version = try #require(versions.first)

        #expect(version.id == 110)
        #expect(version.headCommitSha == "33e2ee8579fda5bc36accc9c6fbd0b4fefda9e30")
        #expect(version.baseCommitSha == "eeb57dffe83deb686a60a71c16c32f71046868fd")
        #expect(version.startCommitSha == "eeb57dffe83deb686a60a71c16c32f71046868fd")
        #expect(version.createdAt == nil)
        #expect(version.mergeRequestId == nil)
        #expect(version.state == nil)
        #expect(version.realSize == nil)
        #expect(version.patchIdSha == nil)
    }
}
