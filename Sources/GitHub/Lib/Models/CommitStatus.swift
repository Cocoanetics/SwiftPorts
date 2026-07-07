import Foundation

// The classic **REST Commit Status API** — `GET /repos/{o}/{r}/commits/{ref}/status`
// (combined) and `.../statuses` (list).
//
// This is a distinct surface from the Checks API (`CheckRun`) and from GitHub's
// GraphQL `statusCheckRollup`, which the `gh` CLI consumes. `gh` does NOT use these
// REST endpoints, so these types are not a port of a `gh` feature — they exist so
// SwiftPorts can read commit statuses (third-party CI that reports via the Statuses
// API, or `gh api` passthrough). No client-side roll-up is performed: `CombinedStatus.state`
// is GitHub's server-precomputed roll-up taken verbatim, unlike `gh`'s `aggregate.go`
// bucketing over the GraphQL rollup.

/// One status from `GET /repos/{o}/{r}/commits/{ref}/statuses`, also embedded in the
/// combined-status response.
public struct CommitStatus: Codable, Sendable, Identifiable {
    public let id: Int
    public let nodeId: String
    /// REST state — lowercase `success` / `failure` / `pending` / `error`. (GitHub's
    /// GraphQL status API, which `gh` uses, spells these UPPERCASE and adds `EXPECTED`;
    /// this REST field never carries `EXPECTED`.)
    public let state: String
    public let description: String?
    public let targetUrl: URL?
    public let context: String
    public let createdAt: Date
    public let updatedAt: Date
    public let url: URL
    public let avatarUrl: URL?
    public let creator: User?
}

/// Combined status for a ref — `GET /repos/{o}/{r}/commits/{ref}/status`.
public struct CombinedStatus: Codable, Sendable {
    /// GitHub's server-computed roll-up — lowercase `success` / `failure` / `pending` /
    /// `error`, taken verbatim (no client-side aggregation like `gh`'s).
    public let state: String
    public let statuses: [CommitStatus]
    public let sha: String
    public let totalCount: Int
    public let repository: MinimalRepository
    public let commitUrl: URL
    public let url: URL
}
