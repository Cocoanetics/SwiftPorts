import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct PrChecks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checks",
        abstract: "Show CI/check-run status for a pull request."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "PR number.")
    var number: Int

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: PrChecksFields.map)
            let gql = try await CommandContext.graphQLClient()
            let response: PullRequestChecksResponse = try await gql.query(
                PullRequestQueries.checks,
                variables: [
                    "owner":  .string(target.owner),
                    "name":   .string(target.name),
                    "number": .int(number),
                ])
            let raw = response.repository?.pullRequest?
                .commits.nodes.last?.commit.statusCheckRollup?.contexts?.nodes ?? []
            // Match upstream gh: stable sort by startedAt descending.
            let contexts = raw.sorted { a, b in
                let ta = a.startedAt ?? a.createdAt ?? .distantPast
                let tb = b.startedAt ?? b.createdAt ?? .distantPast
                return ta > tb
            }
            Stdio.print(try JSONFieldSelector.render(items: contexts, fields: fields, fieldMap: PrChecksFields.map))
            return
        }

        let client = try await CommandContext.apiClient()
        let pr: PullRequest = try await client.get("repos/\(target.slug)/pulls/\(number)")
        let envelope: CheckRunList = try await client.get(
            "repos/\(target.slug)/commits/\(pr.head.sha)/check-runs")

        if envelope.checkRuns.isEmpty {
            Stdio.print("No check runs for #\(number).")
            return
        }
        for c in envelope.checkRuns {
            let outcome = c.conclusion ?? c.status
            let glyph: String
            switch outcome {
            case "success": glyph = ANSI.green("✓")
            case "failure", "cancelled", "timed_out", "action_required":
                glyph = ANSI.red("✗")
            case "skipped", "neutral", "stale": glyph = ANSI.dim("-")
            case "in_progress", "queued", "pending", "waiting":
                glyph = ANSI.yellow("…")
            default: glyph = "?"
            }
            Stdio.print("\(glyph) \(c.name)\t\(outcome)")
        }
    }
}

/// Field map for `gh pr checks --json`.
enum PrChecksFields {
    static let map: [String: @Sendable (GQLStatusCheckContext) -> Any?] = [
        "bucket":      { bucket($0) },
        "completedAt": { (($0.completedAt ?? $0.createdAt).map(JSONFieldSelector.iso8601)) ?? "" },
        "description": { $0.description ?? "" },
        "event":       { $0.checkSuite?.workflowRun?.event ?? "" },
        "link":        { ($0.detailsUrl ?? $0.targetUrl)?.absoluteString ?? "" },
        "name":        { $0.name ?? $0.context ?? "" },
        "startedAt":   { (($0.startedAt ?? $0.createdAt).map(JSONFieldSelector.iso8601)) ?? "" },
        "state":       { $0.conclusion?.uppercased() ?? $0.status?.uppercased() ?? $0.state ?? "" },
        "workflow":    { $0.checkSuite?.workflowRun?.workflow.name ?? "" },
    ]

    /// Mirror gh's check-state → bucket bucketing. CheckRun stores
    /// uppercase conclusion ("SUCCESS"); StatusContext stores upper
    /// state ("SUCCESS"). Lowercase before matching either way.
    private static func bucket(_ c: GQLStatusCheckContext) -> String {
        let outcome = (c.conclusion ?? c.state ?? c.status ?? "").lowercased()
        switch outcome {
        case "success": return "pass"
        case "failure", "timed_out", "action_required", "startup_failure", "stale", "error": return "fail"
        case "cancelled": return "cancel"
        case "skipped", "neutral": return "skipping"
        case "in_progress", "queued", "pending", "waiting", "requested", "expected": return "pending"
        default: return ""
        }
    }
}
