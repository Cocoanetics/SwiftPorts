import Foundation
import Testing
@testable import GitLab

@Suite struct MergeRequestDecodingTests {
    @Test func decodesMergeRequest() throws {
        let json = """
        {
          "id": 1, "iid": 11, "project_id": 7,
          "title": "Add HELLO.md", "description": "body",
          "state": "opened",
          "draft": false, "work_in_progress": false,
          "created_at": "2024-09-01T12:00:00.000Z",
          "updated_at": "2024-09-01T12:30:00.000Z",
          "closed_at": null, "merged_at": null,
          "target_branch": "main", "source_branch": "feature/hello",
          "user_notes_count": 2, "upvotes": 0, "downvotes": 0,
          "labels": ["smoke"], "milestone": null,
          "author": {"id": 100, "username": "alice", "name": "A", "state": "active", "avatar_url": null, "web_url": "https://example.com/alice"},
          "assignee": null, "assignees": [], "reviewers": [],
          "merged_by": null, "closed_by": null,
          "source_project_id": 7, "target_project_id": 7,
          "web_url": "https://example.com/g/r/-/merge_requests/11",
          "merge_status": "can_be_merged", "detailed_merge_status": "mergeable",
          "sha": "deadbeef", "merge_commit_sha": null, "squash_commit_sha": null,
          "discussion_locked": false, "should_remove_source_branch": null,
          "force_remove_source_branch": false, "squash": false, "has_conflicts": false,
          "pipeline": {
            "id": 9876, "iid": 12, "project_id": 7,
            "sha": "deadbeef", "ref": "feature/hello",
            "status": "success", "source": "push",
            "web_url": "https://example.com/g/r/-/pipelines/9876"
          },
          "head_pipeline": {
            "id": 9877, "iid": 13, "project_id": 7,
            "sha": "deadbeef", "ref": "refs/merge-requests/11/head",
            "status": "running", "source": "merge_request_event",
            "web_url": "https://example.com/g/r/-/pipelines/9877"
          }
        }
        """.data(using: .utf8)!
        let mr = try JSONDecoder.gitLab().decode(MergeRequest.self, from: json)
        #expect(mr.iid == 11)
        #expect(mr.state == .opened)
        #expect(mr.detailedMergeStatus == .mergeable)
        #expect(mr.detailedMergeStatus?.isMergeable == true)
        #expect(mr.detailedMergeStatus?.isTransient == false)
        #expect(mr.sourceBranch == "feature/hello")
        #expect(mr.targetBranch == "main")
        #expect(mr.author?.username == "alice")
        #expect(mr.pipeline?.status == .success)
        #expect(mr.headPipeline?.id == 9877)
        #expect(mr.headPipeline?.status == .running)
    }

    @Test func decodesUnknownStateGracefully() throws {
        let json = """
        {
          "id": 1, "iid": 1, "project_id": 1,
          "title": "x", "state": "weird_future_state",
          "target_branch": "main", "source_branch": "f",
          "labels": [], "web_url": "https://x/y/-/merge_requests/1"
        }
        """.data(using: .utf8)!
        let mr = try JSONDecoder.gitLab().decode(MergeRequest.self, from: json)
        #expect(mr.state == .unknown("weird_future_state"))
    }

    @Test func decodesUnknownDetailedMergeStatusGracefully() throws {
        let json = """
        {
          "id": 1, "iid": 1, "project_id": 1,
          "title": "x", "state": "opened",
          "target_branch": "main", "source_branch": "f",
          "labels": [], "web_url": "https://x/y/-/merge_requests/1",
          "detailed_merge_status": "future_status"
        }
        """.data(using: .utf8)!
        let mr = try JSONDecoder.gitLab().decode(MergeRequest.self, from: json)
        #expect(mr.detailedMergeStatus == .unknown("future_status"))
        #expect(mr.detailedMergeStatus?.rawValue == "future_status")
    }

    @Test func detailedMergeStatusClassifiesMergeability() {
        #expect(DetailedMergeStatus.mergeable.isMergeable)
        #expect(!DetailedMergeStatus.mergeable.isTransient)
        #expect(DetailedMergeStatus.checking.isTransient)
        #expect(DetailedMergeStatus.preparing.isTransient)
        #expect(DetailedMergeStatus.unchecked.isTransient)
        #expect(DetailedMergeStatus.approvalsSyncing.isTransient)
        #expect(DetailedMergeStatus.ciStillRunning.isTransient)
        #expect(!DetailedMergeStatus.conflict.isMergeable)
        #expect(!DetailedMergeStatus.conflict.isTransient)
        #expect(!DetailedMergeStatus.ciMustPass.isTransient)
    }
}

@Suite struct ProjectDecodingTests {
    @Test func decodesProject() throws {
        let json = """
        {
          "id": 168, "name": "Glab Sandbox", "path": "glab-sandbox",
          "path_with_namespace": "labs/glab-sandbox",
          "description": "test repo",
          "default_branch": "main", "visibility": "private",
          "archived": false,
          "web_url": "https://example.com/labs/glab-sandbox",
          "http_url_to_repo": "https://example.com/labs/glab-sandbox.git",
          "ssh_url_to_repo": "git@example.com:labs/glab-sandbox.git",
          "created_at": "2024-09-01T12:00:00.000Z",
          "last_activity_at": "2024-09-02T12:00:00.000Z",
          "star_count": 0, "forks_count": 0, "open_issues_count": 3,
          "issues_enabled": true, "merge_requests_enabled": true,
          "wiki_enabled": false, "snippets_enabled": false,
          "empty_repo": false,
          "namespace": {
            "id": 8, "name": "Cocoanetics Labs", "path": "labs",
            "kind": "group", "full_path": "labs",
            "web_url": "https://example.com/groups/labs"
          }
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder.gitLab().decode(Project.self, from: json)
        #expect(p.id == 168)
        #expect(p.pathWithNamespace == "labs/glab-sandbox")
        #expect(p.defaultBranch == "main")
        #expect(p.namespace?.fullPath == "labs")
    }
}
