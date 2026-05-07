import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct RunList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent workflow runs."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("limit")], help: "Maximum runs to fetch.")
    var limit: Int = 30

    @Option(name: .customLong("workflow"),
            help: "Filter by workflow ID or filename.")
    var workflow: String?

    @Option(name: .customLong("branch"),
            help: "Filter by branch.")
    var branch: String?

    @Option(name: .customLong("status"),
            help: "Filter by status (queued, in_progress, completed).")
    var status: String?

    @Option(name: .customLong("event"),
            help: "Filter by event (push, pull_request, etc).")
    var event: String?

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()

        let path: String
        if let workflow {
            path = "repos/\(target.slug)/actions/workflows/\(workflow)/runs"
        } else {
            path = "repos/\(target.slug)/actions/runs"
        }

        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(min(limit, 100))),
        ]
        if let branch { query.append(URLQueryItem(name: "branch", value: branch)) }
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let event { query.append(URLQueryItem(name: "event", value: event)) }

        let envelope: WorkflowRunList = try await client.get(path, query: query)
        let trimmed = Array(envelope.workflowRuns.prefix(limit))

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: RunFields.list)
            Stdio.print(try JSONFieldSelector.render(items: trimmed, fields: fields, fieldMap: RunFields.list))
            return
        }
        if trimmed.isEmpty {
            Stdio.print("No runs match.")
            return
        }
        for run in trimmed {
            let status = run.conclusion ?? run.status ?? "?"
            let title = run.displayTitle ?? run.name ?? "?"
            let when = ISO8601DateFormatter().string(from: run.createdAt)
            Stdio.print("\(run.id)\t\(status)\t\(run.event)\t\(title)\t\(run.headBranch ?? "-")\t\(when)")
        }
    }
}

enum RunFields {
    /// Fields exposed by `gh run list --json` and `gh run view --json`.
    /// Names and ordering match upstream gh.
    static let list: [String: @Sendable (WorkflowRun) -> Any?] = [
        "attempt":            { $0.runAttempt },
        "conclusion":         { $0.conclusion },
        "createdAt":          { JSONFieldSelector.iso8601($0.createdAt) },
        "databaseId":         { $0.id },
        "displayTitle":       { $0.displayTitle },
        "event":              { $0.event },
        "headBranch":         { $0.headBranch },
        "headSha":            { $0.headSha },
        "name":               { $0.name },
        "number":             { $0.runNumber },
        "startedAt":          { $0.runStartedAt.map(JSONFieldSelector.iso8601) },
        "status":             { $0.status },
        "updatedAt":          { JSONFieldSelector.iso8601($0.updatedAt) },
        "url":                { $0.htmlUrl.absoluteString },
        "workflowDatabaseId": { $0.workflowId },
        "workflowName":       { $0.name },
    ]
}
