import Foundation
import Testing
@testable import GitLab

@Suite struct DiscussionDecodingTests {
    @Test func decodesMergeRequestDiscussionPositionAndResolution() throws {
        let json = """
        [
          {
            "id": "87805b7c09016a7058e91bdbe7b29d1f284a39e6",
            "individual_note": false,
            "notes": [
              {
                "id": 1128,
                "type": "DiffNote",
                "body": "diff comment",
                "author": {
                  "id": 1,
                  "username": "root",
                  "name": "Root",
                  "state": "active",
                  "avatar_url": null,
                  "web_url": "https://gitlab.example.com/root"
                },
                "created_at": "2018-03-04T09:17:22.520Z",
                "updated_at": "2018-03-04T09:18:22.520Z",
                "system": false,
                "noteable_id": 3,
                "noteable_type": "MergeRequest",
                "noteable_iid": null,
                "resolvable": true,
                "resolved": false,
                "resolved_by": {
                  "id": 2,
                  "username": "alice",
                  "name": "Alice",
                  "state": "active",
                  "avatar_url": null,
                  "web_url": "https://gitlab.example.com/alice"
                },
                "position": {
                  "base_sha": "b5d6e7b1613fca24d250fa8e5bc7bcc3dd6002ef",
                  "start_sha": "7c9c2ead8a320fb7ba0b4e234bd9529a2614e306",
                  "head_sha": "4803c71e6b1833ca72b8b26ef2ecd5adc8a38031",
                  "old_path": "Sources/App.swift",
                  "new_path": "Sources/App.swift",
                  "position_type": "text",
                  "old_line": 41,
                  "new_line": 42,
                  "line_range": {
                    "start": {
                      "line_code": "abc_40_41",
                      "type": "new",
                      "old_line": 40,
                      "new_line": 41
                    },
                    "end": {
                      "line_code": "abc_41_42",
                      "type": "new",
                      "old_line": 41,
                      "new_line": 42
                    }
                  }
                }
              },
              {
                "id": 1129,
                "type": "DiscussionNote",
                "body": "reply",
                "author": {"id": 1, "username": "root"},
                "created_at": "2018-03-04T10:17:22Z",
                "updated_at": "2018-03-04T10:18:22Z",
                "system": false,
                "noteable_id": 3,
                "noteable_type": "MergeRequest",
                "resolvable": true,
                "resolved": false,
                "resolved_by": null
              }
            ]
          }
        ]
        """.data(using: .utf8)!

        let discussions = try JSONDecoder.gitLab().decode([Discussion].self, from: json)
        let discussion = try #require(discussions.first)
        let note = try #require(discussion.notes.first)

        #expect(discussion.id == "87805b7c09016a7058e91bdbe7b29d1f284a39e6")
        #expect(discussion.individualNote == false)
        #expect(note.type == "DiffNote")
        #expect(note.resolvable == true)
        #expect(note.resolved == false)
        #expect(note.resolvedBy?.username == "alice")
        #expect(note.position?.newPath == "Sources/App.swift")
        #expect(note.position?.newLine == 42)
        #expect(note.position?.lineRange?.start?.oldLine == 40)
        #expect(note.position?.oldPath == "Sources/App.swift")
        #expect(discussion.notes[1].type == "DiscussionNote")
    }
}
