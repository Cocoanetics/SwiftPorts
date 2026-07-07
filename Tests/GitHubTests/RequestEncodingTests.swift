import Foundation
import Testing
@testable import GitHub

/// Verify that write-request bodies encode to the snake_case wire
/// format GitHub expects, via the shared `JSONEncoder.gitHub()`.
@Suite struct RequestEncodingTests {
    @Test func issueCreateBody() throws {
        let request = IssueCreateRequest(
            title: "Hello",
            body: "World",
            assignees: ["octocat"],
            labels: ["bug", "good-first-issue"],
            milestone: 3
        )
        let data = try JSONEncoder.gitHub().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["title"] as? String == "Hello")
        #expect(object["body"] as? String == "World")
        #expect(object["assignees"] as? [String] == ["octocat"])
        #expect(object["labels"] as? [String] == ["bug", "good-first-issue"])
        #expect(object["milestone"] as? Int == 3)
    }

    @Test func issueStateUpdateUsesSnakeCase() throws {
        let request = IssueStateUpdateRequest.close(reason: "completed")
        let data = try JSONEncoder.gitHub().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["state"] as? String == "closed")
        #expect(object["state_reason"] as? String == "completed")
    }

    @Test func releaseCreateBody() throws {
        let request = ReleaseCreateRequest(
            tagName: "v1.2.3",
            name: "Spring Release",
            body: "notes",
            draft: true,
            prerelease: false,
            targetCommitish: "main",
            generateReleaseNotes: true
        )
        let data = try JSONEncoder.gitHub().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["tag_name"] as? String == "v1.2.3")
        #expect(object["target_commitish"] as? String == "main")
        #expect(object["generate_release_notes"] as? Bool == true)
        #expect(object["draft"] as? Bool == true)
    }

    @Test func gistCreateBody() throws {
        let request = GistCreateRequest(
            description: "test",
            public: false,
            files: ["a.txt": GistFileContent(content: "hello")])
        let data = try JSONEncoder.gitHub().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["description"] as? String == "test")
        #expect(object["public"] as? Bool == false)
        let files = object["files"] as! [String: [String: Any]]
        #expect(files["a.txt"]?["content"] as? String == "hello")
    }

    @Test func issueCommentBodyJustBody() throws {
        let request = IssueCommentRequest(body: "👍")
        let data = try JSONEncoder.gitHub().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["body"] as? String == "👍")
        #expect(object.keys.count == 1)
    }

    @Test func addReactionBodyUsesWireContent() throws {
        let cases: [(ReactionContent, String)] = [
            (.plus1, "+1"),
            (.minus1, "-1"),
            (.laugh, "laugh"),
            (.confused, "confused"),
            (.heart, "heart"),
            (.hooray, "hooray"),
            (.rocket, "rocket"),
            (.eyes, "eyes"),
        ]

        for (content, rawValue) in cases {
            let request = AddReactionRequest(content: content)
            let data = try JSONEncoder.gitHub().encode(request)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            #expect(object["content"] as? String == rawValue)
            #expect(object.keys.count == 1)
        }
    }
}
