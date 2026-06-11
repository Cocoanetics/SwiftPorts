import Foundation
import Testing
@testable import GitHub

/// `GET pulls/{n}/reviews` and `GET pulls/{n}/comments` payloads
/// (issue #67).
@Suite struct PullReviewDecodingTests {

    @Test func decodesReviewList() throws {
        let data = try FixtureLoader.data("pr_reviews_cli")
        let reviews = try JSONDecoder.gitHub()
            .decode([PullReview].self, from: data)

        #expect(reviews.count == 3)

        let approved = reviews[0]
        #expect(approved.id == 80)
        #expect(approved.state == .approved)
        #expect(approved.user?.login == "vilmibm")
        #expect(approved.body == "Looks great, one nit inline.")
        #expect(approved.submittedAt != nil)
        #expect(approved.commitId
                == "ecdd80bb57125d7ba9641ffaa4d7d2c19d3f3091")
        #expect(approved.authorAssociation == .member)

        #expect(reviews[1].state == .changesRequested)

        // A PENDING review hasn't been submitted: no `submitted_at`,
        // and `commit_id` can be null.
        let pending = reviews[2]
        #expect(pending.state == .pending)
        #expect(pending.submittedAt == nil)
        #expect(pending.commitId == nil)
    }

    @Test func decodesReviewCommentList() throws {
        let data = try FixtureLoader.data("pr_review_comments_cli")
        let comments = try JSONDecoder.gitHub()
            .decode([PullReviewComment].self, from: data)

        #expect(comments.count == 2)

        let root = comments[0]
        #expect(root.id == 10)
        #expect(root.pullRequestReviewId == 80)
        #expect(root.path == "cmd/gh/main.go")
        #expect(root.diffHunk.hasPrefix("@@ -16,33 +16,40 @@"))
        #expect(root.line == 22)
        #expect(root.originalLine == 22)
        #expect(root.side == "RIGHT")
        #expect(root.subjectType == "line")
        #expect(root.inReplyToId == nil)
        #expect(root.user.login == "vilmibm")
        #expect(root.reactions?.totalCount == 1)
        #expect(root.reactions?.plus1 == 1)

        // The reply threads via `in_reply_to_id`; its current-diff
        // anchor went stale (`line` null) while `original_line`
        // keeps the position in the diff it was written against.
        let reply = comments[1]
        #expect(reply.inReplyToId == 10)
        #expect(reply.line == nil)
        #expect(reply.originalLine == 22)
        #expect(reply.position == nil)
        #expect(reply.originalPosition == 4)
        #expect(reply.reactions == nil)
    }
}
