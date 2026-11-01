import Foundation
import Testing
@testable import GitHub

@Suite struct PullRequestDecodingTests {
    @Test func decodesCliFirstPR() throws {
        let data = try FixtureLoader.data("pr_cli_1")
        let pr = try JSONDecoder.gitHub().decode(PullRequest.self, from: data)

        #expect(pr.number == 1)
        #expect(pr.state == .closed)
        #expect(pr.user.login == "vilmibm")
        #expect(pr.head.ref.isEmpty == false)
        #expect(pr.base.ref.isEmpty == false)
        #expect(pr.merged != nil)
    }

    @Test(arguments: ["merge", "squash", "rebase"])
    func decodesAutoMerge(method: String) throws {
        let data = try FixtureLoader.data("pr_cli_1")
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["auto_merge"] = [
            "enabled_by": try #require(json["user"]),
            "merge_method": method,
            "commit_title": "Merge when ready",
            "commit_message": "Required checks must pass",
        ]
        let pr = try JSONDecoder.gitHub().decode(
            PullRequest.self, from: JSONSerialization.data(withJSONObject: json))
        let autoMerge = try #require(pr.autoMerge)
        #expect(autoMerge.enabledBy.login == "vilmibm")
        #expect(autoMerge.mergeMethod.rawValue == method)
        #expect(autoMerge.commitTitle == "Merge when ready")
        #expect(autoMerge.commitMessage == "Required checks must pass")

        let encoded = try JSONEncoder.gitHub().encode(pr)
        let roundTrip = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedAutoMerge = try #require(roundTrip["auto_merge"] as? [String: Any])
        #expect(encodedAutoMerge["merge_method"] as? String == method)
        #expect(encodedAutoMerge["enabled_by"] != nil)
    }

    @Test(arguments: [true, false])
    func decodesDisabledOrMissingAutoMerge(explicitNull: Bool) throws {
        let data = try FixtureLoader.data("pr_cli_1")
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "auto_merge")
        if explicitNull { json["auto_merge"] = NSNull() }
        let pr = try JSONDecoder.gitHub().decode(
            PullRequest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(pr.autoMerge == nil)
    }

    @Test(arguments: [true, false])
    func decodesAutoMergeWithoutCommitOverrides(explicitNull: Bool) throws {
        let data = try FixtureLoader.data("pr_cli_1")
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var autoMerge: [String: Any] = [
            "enabled_by": try #require(json["user"]),
            "merge_method": "squash",
        ]
        if explicitNull {
            autoMerge["commit_title"] = NSNull()
            autoMerge["commit_message"] = NSNull()
        }
        json["auto_merge"] = autoMerge
        let pr = try JSONDecoder.gitHub().decode(
            PullRequest.self, from: JSONSerialization.data(withJSONObject: json))
        let decoded = try #require(pr.autoMerge)
        #expect(decoded.commitTitle == nil)
        #expect(decoded.commitMessage == nil)
    }
}
