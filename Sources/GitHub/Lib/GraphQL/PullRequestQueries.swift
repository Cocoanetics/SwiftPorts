import Foundation

/// GraphQL queries that mirror upstream `gh`'s `pr list`/`pr view`
/// `--json` paths. Selecting a wide field set keeps the wire format
/// byte-identical with `gh`'s output for the most-used field names.
public enum PullRequestQueries {

    /// Reusable PR field selection — kept as one block so list/view
    /// stay in sync. Anything added here becomes available to every
    /// `--json` consumer.
    private static let prFields = """
        id
        fullDatabaseId
        number
        title
        state
        body
        url
        createdAt
        updatedAt
        closedAt
        mergedAt
        isDraft
        additions
        deletions
        changedFiles
        baseRefName
        baseRefOid
        headRefName
        headRefOid
        reviewDecision
        mergeable
        mergeStateStatus
        maintainerCanModify
        isCrossRepository
        author {
          __typename
          login
          ... on User { id name }
          ... on Bot { id }
        }
        mergedBy {
          __typename
          login
          ... on User { id name }
          ... on Bot { id }
        }
        headRepository {
          id name
          owner { login }
        }
        headRepositoryOwner {
          __typename
          id login
        }
        baseRepository {
          id name
          owner { login }
        }
        labels(first: 100) {
          nodes { id name color description }
        }
        assignees(first: 100) {
          nodes { id login name }
        }
        milestone {
          number title description dueOn
        }
        comments(first: 0) { totalCount }
        commits(first: 100) {
          totalCount
          nodes {
            commit {
              oid
              messageHeadline
              messageBody
              committedDate
              authoredDate
              additions
              deletions
              authors(first: 10) {
                nodes {
                  email name
                  user { id login }
                }
              }
              statusCheckRollup { state }
            }
          }
        }
        files(first: 100) {
          nodes { path additions deletions }
        }
        latestReviews: reviews(last: 100) {
          nodes {
            id
            authorAssociation
            body
            submittedAt
            includesCreatedEdit
            state
            author { login }
            commit { oid }
            reactionGroups {
              content
              users(first: 0) { totalCount }
              reactors(first: 0) { totalCount }
            }
          }
        }
        reviews(first: 0) { totalCount }
        reactionGroups {
          content
          users(first: 0) { totalCount }
          reactors(first: 0) { totalCount }
        }
        closingIssuesReferences(first: 100) {
          nodes { number title url state }
        }
        autoMergeRequest {
          enabledAt mergeMethod
          enabledBy { login }
        }
        mergeCommit { oid }
        potentialMergeCommit { oid }
        reviewRequests(first: 100) {
          nodes {
            requestedReviewer {
              __typename
              ... on User { login }
              ... on Team { name slug }
              ... on Mannequin { login }
            }
          }
        }
        projectItems(first: 100) {
          nodes {
            id
            project { id title number url }
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
            }
          }
        }
        statusCheckRollup: commits(last: 1) {
          nodes {
            commit {
              statusCheckRollup {
                contexts(first: 100) {
                  nodes {
                    __typename
                    ... on StatusContext {
                      context state targetUrl description createdAt
                    }
                    ... on CheckRun {
                      name conclusion status startedAt completedAt
                      detailsUrl
                      checkSuite { workflowRun { event workflow { name } } }
                    }
                  }
                }
              }
            }
          }
        }
        """

    public static func list(includeFields: Bool = true) -> String {
        """
        query($owner: String!, $name: String!, $first: Int!, $states: [PullRequestState!], $base: String, $head: String) {
          repository(owner: $owner, name: $name) {
            pullRequests(
              first: $first,
              states: $states,
              baseRefName: $base,
              headRefName: $head,
              orderBy: {field: CREATED_AT, direction: DESC}
            ) {
              totalCount
              nodes {
                \(prFields)
              }
            }
          }
        }
        """
    }

    public static func view() -> String {
        """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              \(prFields)
            }
          }
        }
        """
    }

    /// Slim query for `gh pr checks` — only the latest commit's
    /// status-check rollup contexts.
    public static let checks = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              commits(last: 1) {
                nodes {
                  commit {
                    statusCheckRollup {
                      contexts(first: 100) {
                        nodes {
                          __typename
                          ... on StatusContext {
                            context state targetUrl description createdAt
                          }
                          ... on CheckRun {
                            name conclusion status startedAt completedAt
                            detailsUrl
                            checkSuite { workflowRun { event workflow { name } } }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """

    /// Review-thread lookup for resolving a thread by one of its REST
    /// review-comment database IDs. GitHub exposes thread resolution
    /// only through GraphQL.
    public static let reviewThreads = """
        query($owner: String!, $name: String!, $number: Int!, $first: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: $first) {
                nodes {
                  id
                  isResolved
                  isOutdated
                  comments(first: 100) {
                    nodes { databaseId }
                  }
                }
              }
            }
          }
        }
        """
}

public struct PullRequestChecksResponse: Codable, Sendable {
    public let repository: Container?
    public struct Container: Codable, Sendable {
        public let pullRequest: PRWrapper?
    }
    public struct PRWrapper: Codable, Sendable {
        public let commits: GQLNodeList<GQLStatusCheckCommitWrap>
    }
}

public struct PullRequestReviewThreadsResponse: Codable, Sendable {
    public let repository: Container?
    public struct Container: Codable, Sendable {
        public let pullRequest: PRWrapper?
    }
    public struct PRWrapper: Codable, Sendable {
        public let reviewThreads: PullRequestReviewThreadConnection
    }
}

// MARK: Response envelopes

public struct PullRequestListResponse: Codable, Sendable {
    public let repository: Container?
    public struct Container: Codable, Sendable {
        public let pullRequests: PullRequestConnection
    }
}

public struct PullRequestViewResponse: Codable, Sendable {
    public let repository: Container?
    public struct Container: Codable, Sendable {
        public let pullRequest: GraphQLPullRequest?
    }
}

public struct PullRequestConnection: Codable, Sendable {
    public let totalCount: Int
    public let nodes: [GraphQLPullRequest]
}

public struct PullRequestReviewThreadConnection: Codable, Sendable {
    public let nodes: [PullRequestReviewThread]
}

public struct PullRequestReviewThread: Codable, Sendable, Identifiable {
    public let id: String
    public let isResolved: Bool
    public let isOutdated: Bool
    public let comments: GQLNodeList<PullRequestReviewThreadComment>
}

public struct PullRequestReviewThreadComment: Codable, Sendable {
    public let databaseId: Int?
}

// MARK: GraphQLPullRequest

public struct GraphQLPullRequest: Codable, Sendable {
    public let id: String
    public let fullDatabaseId: String?
    public let number: Int
    public let title: String
    public let state: String
    public let body: String
    public let url: URL
    public let createdAt: Date
    public let updatedAt: Date
    public let closedAt: Date?
    public let mergedAt: Date?
    public let isDraft: Bool
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let baseRefName: String
    public let baseRefOid: String
    public let headRefName: String
    public let headRefOid: String
    public let reviewDecision: String?
    public let mergeable: String
    public let mergeStateStatus: String
    public let maintainerCanModify: Bool
    public let isCrossRepository: Bool
    public let author: GQLActor?
    public let mergedBy: GQLActor?
    public let headRepository: GQLRepoStub?
    public let headRepositoryOwner: GQLOwner?
    public let baseRepository: GQLRepoStub?
    public let labels: GQLNodeList<GQLLabel>?
    public let assignees: GQLNodeList<GQLUser>?
    public let milestone: GQLMilestone?
    public let comments: GQLCount?
    public let commits: GQLNodeListWithCount<GQLCommitWrap>?
    public let files: GQLNodeList<GQLFile>?
    public let latestReviews: GQLNodeList<GQLReview>?
    public let reviews: GQLCount?
    public let reactionGroups: [GQLReactionGroup]?
    public let closingIssuesReferences: GQLNodeList<GQLIssueRef>?
    public let autoMergeRequest: GQLAutoMerge?
    public let mergeCommit: GQLOid?
    public let potentialMergeCommit: GQLOid?
    public let reviewRequests: GQLNodeList<GQLReviewRequest>?
    public let projectItems: GQLNodeList<GQLProjectItem>?
    public let statusCheckRollup: GQLNodeList<GQLStatusCheckCommitWrap>?
}

public struct GQLReviewRequest: Codable, Sendable {
    public let requestedReviewer: GQLRequestedReviewer?
}

public struct GQLRequestedReviewer: Codable, Sendable {
    public let typename: String
    public let login: String?
    public let name: String?
    public let slug: String?

    enum CodingKeys: String, CodingKey {
        case login, name, slug
        case typename = "__typename"
    }
}

public struct GQLProjectItem: Codable, Sendable {
    public let id: String
    public let project: GQLProjectStub?
    public let fieldValueByName: GQLProjectStatusValue?
}

public struct GQLProjectStub: Codable, Sendable {
    public let id: String
    public let title: String
    public let number: Int
    public let url: URL
}

public struct GQLProjectStatusValue: Codable, Sendable {
    public let name: String?
    public let optionId: String?
}

// MARK: Common GraphQL nested types

public struct GQLActor: Codable, Sendable {
    public let typename: String
    public let login: String
    public let id: String?
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case login, id, name
        case typename = "__typename"
    }
}

public struct GQLOwner: Codable, Sendable {
    public let typename: String
    public let id: String
    public let login: String

    enum CodingKeys: String, CodingKey {
        case id, login
        case typename = "__typename"
    }
}

public struct GQLRepoStub: Codable, Sendable {
    public let id: String
    public let name: String
    public let owner: OwnerInner?
    public struct OwnerInner: Codable, Sendable {
        public let login: String
    }
    public var nameWithOwner: String { (owner.map { "\($0.login)/" } ?? "") + name }
}

public struct GQLLabel: Codable, Sendable {
    public let id: String
    public let name: String
    public let color: String
    public let description: String?
}

public struct GQLUser: Codable, Sendable {
    public let id: String
    public let login: String
    public let name: String?
}

public struct GQLMilestone: Codable, Sendable {
    public let number: Int
    public let title: String
    public let description: String?
    public let dueOn: Date?
}

public struct GQLCount: Codable, Sendable { public let totalCount: Int }

public struct GQLNodeList<T: Codable & Sendable>: Codable, Sendable {
    public let nodes: [T]
}

public struct GQLNodeListWithCount<T: Codable & Sendable>: Codable, Sendable {
    public let totalCount: Int
    public let nodes: [T]
}

public struct GQLCommitWrap: Codable, Sendable {
    public let commit: GQLCommit
}

public struct GQLCommit: Codable, Sendable {
    public let oid: String
    public let messageHeadline: String
    public let messageBody: String
    public let committedDate: Date
    public let authoredDate: Date
    public let additions: Int?
    public let deletions: Int?
    public let authors: GQLNodeList<GQLCommitAuthor>?
    public let statusCheckRollup: GQLStatusCheckRollup?
}

public struct GQLCommitAuthor: Codable, Sendable {
    public let email: String?
    public let name: String?
    public let user: GQLUserStub?
    public struct GQLUserStub: Codable, Sendable {
        public let id: String
        public let login: String
    }
}

public struct GQLStatusCheckRollup: Codable, Sendable { public let state: String }

public struct GQLFile: Codable, Sendable {
    public let path: String
    public let additions: Int
    public let deletions: Int
}

public struct GQLReview: Codable, Sendable {
    public let id: String
    public let authorAssociation: String
    public let body: String
    public let submittedAt: Date?
    public let includesCreatedEdit: Bool
    public let state: String
    public let author: GQLActorLogin?
    public let commit: GQLOid?
    public let reactionGroups: [GQLReactionGroup]?
}

public struct GQLActorLogin: Codable, Sendable { public let login: String }

public struct GQLOid: Codable, Sendable { public let oid: String }

public struct GQLReactionGroup: Codable, Sendable {
    public let content: String
    public let users: GQLCount?
    public let reactors: GQLCount?
}

public struct GQLIssueRef: Codable, Sendable {
    public let number: Int
    public let title: String
    public let url: URL
    public let state: String
}

public struct GQLAutoMerge: Codable, Sendable {
    public let enabledAt: Date?
    public let mergeMethod: String?
    public let enabledBy: GQLActorLogin?
}

public struct GQLStatusCheckCommitWrap: Codable, Sendable {
    public let commit: GQLStatusCheckCommit
}

public struct GQLStatusCheckCommit: Codable, Sendable {
    public let statusCheckRollup: GQLStatusCheckRollupContexts?
}

public struct GQLStatusCheckRollupContexts: Codable, Sendable {
    public let contexts: GQLNodeList<GQLStatusCheckContext>?
}

public struct GQLStatusCheckContext: Codable, Sendable {
    public let typename: String
    public let context: String?
    public let state: String?
    public let targetUrl: URL?
    public let description: String?
    public let createdAt: Date?
    public let name: String?
    public let conclusion: String?
    public let status: String?
    public let startedAt: Date?
    public let completedAt: Date?
    public let detailsUrl: URL?
    public let checkSuite: GQLCheckSuite?

    enum CodingKeys: String, CodingKey {
        case context, state, targetUrl, description, createdAt
        case name, conclusion, status, startedAt, completedAt, detailsUrl, checkSuite
        case typename = "__typename"
    }
}

public struct GQLCheckSuite: Codable, Sendable {
    public let workflowRun: GQLWorkflowRunInfo?
    public struct GQLWorkflowRunInfo: Codable, Sendable {
        public let event: String
        public let workflow: GQLWorkflowName
    }
    public struct GQLWorkflowName: Codable, Sendable { public let name: String }
}
