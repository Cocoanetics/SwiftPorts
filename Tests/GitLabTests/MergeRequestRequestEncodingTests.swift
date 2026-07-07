import Foundation
import Testing
@testable import GitLab

@Suite struct MergeRequestRequestEncodingTests {
    @Test func createBodyUsesGitLabFieldNames() throws {
        let request = MergeRequestCreateRequest(
            title: "Add foo",
            sourceBranch: "feat/foo",
            targetBranch: "main",
            description: "Long body",
            labels: "bug,backend",
            assigneeIds: [1, 2],
            reviewerIds: [3],
            milestoneId: 4,
            removeSourceBranch: true,
            squash: false)
        let data = try JSONEncoder.gitLab().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["title"] as? String == "Add foo")
        #expect(object["source_branch"] as? String == "feat/foo")
        #expect(object["target_branch"] as? String == "main")
        #expect(object["description"] as? String == "Long body")
        #expect(object["labels"] as? String == "bug,backend")
        #expect(object["assignee_ids"] as? [Int] == [1, 2])
        #expect(object["reviewer_ids"] as? [Int] == [3])
        #expect(object["milestone_id"] as? Int == 4)
        #expect(object["remove_source_branch"] as? Bool == true)
        #expect(object["squash"] as? Bool == false)
    }
}
