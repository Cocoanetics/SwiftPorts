import ArgumentParser
import Sandbox
import Foundation
import HTTPTypes
import GitHub
import ForgeKit

struct RunView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "View a workflow run.",
        discussion: """
        Default output: run-level summary.

        --jobs           Lists each job in the run with its status / conclusion.
        --job ID         Drills into a single job, listing each step.
        --log            Streams the run's full logs (downloads, unzips, prints).
        --log-failed     Like --log but only the failed jobs' logs.
        --exit-status    Exit non-zero if the run's conclusion isn't 'success'.
                         Useful in scripts: `gh run view ID --exit-status && deploy`.
        """
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Run ID.")
    var id: Int

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    @Flag(name: .long, help: "List each job in the run.")
    var jobs: Bool = false

    @Option(name: .customLong("job"),
            help: "Drill into a single job by ID; lists its steps.")
    var jobId: Int?

    @Flag(name: .long, help: "Print all job logs to stdout.")
    var log: Bool = false

    @Flag(name: .customLong("log-failed"),
          help: "Print only the failed jobs' logs.")
    var logFailed: Bool = false

    @Flag(name: .customLong("exit-status"),
          help: "Exit non-zero if conclusion != 'success'.")
    var exitStatus: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()

        if let jobId {
            let job: WorkflowJob = try await client.get(
                "repos/\(target.slug)/actions/jobs/\(jobId)")
            // The single-job endpoint isn't a `gh` shape; pretty-print
            // is fine here since this is our own affordance.
            if json != nil {
                Stdio.print(try CodableOutput.prettyJSON(job))
                return
            }
            renderJob(job)
            return
        }

        let run: WorkflowRun = try await client.get(
            "repos/\(target.slug)/actions/runs/\(id)")

        if log || logFailed {
            try await downloadAndPrintLogs(
                client: client, slug: target.slug, runId: id, failedOnly: logFailed)
            if exitStatus {
                try enforceExit(run.conclusion)
            }
            return
        }

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: RunViewFields.map)
            // Lazy-fetch jobs only if the user requested it.
            let runWithJobs: RunWithJobs
            if fields.contains("jobs") {
                let envelope: WorkflowJobList = try await client.get(
                    "repos/\(target.slug)/actions/runs/\(id)/jobs")
                runWithJobs = RunWithJobs(run: run, jobs: envelope.jobs)
            } else {
                runWithJobs = RunWithJobs(run: run, jobs: [])
            }
            Stdio.print(try JSONFieldSelector.render(item: runWithJobs, fields: fields, fieldMap: RunViewFields.map))
            if exitStatus { try enforceExit(run.conclusion) }
            return
        }

        renderRunSummary(run)

        if jobs {
            let envelope: WorkflowJobList = try await client.get(
                "repos/\(target.slug)/actions/runs/\(id)/jobs")
            Stdio.print("")
            Stdio.print(ANSI.bold("Jobs (\(envelope.jobs.count)):"))
            for job in envelope.jobs {
                let glyph = conclusionGlyph(job.conclusion ?? job.status)
                let dur = job.startedAt.flatMap { start in
                    job.completedAt.map { end in
                        Self.formatDuration(end.timeIntervalSince(start))
                    }
                } ?? "-"
                Stdio.print("  \(glyph) \(job.name)\t#\(job.id)\t\(dur)")
            }
        }

        if exitStatus { try enforceExit(run.conclusion) }
    }

    // MARK: Rendering

    private func renderRunSummary(_ run: WorkflowRun) {
        Stdio.print("\(ANSI.bold("Run #\(run.runNumber)")): \(run.displayTitle ?? run.name ?? "?")")
        let status = run.conclusion ?? run.status ?? "-"
        Stdio.print("status: \(conclusionGlyph(status)) \(status)")
        Stdio.print("event: \(run.event)  branch: \(run.headBranch ?? "-")  sha: \(String(run.headSha.prefix(7)))")
        if let actor = run.actor { Stdio.print("actor: @\(actor.login)") }
        if let started = run.runStartedAt {
            Stdio.print("started: \(ISO8601DateFormatter().string(from: started))")
        }
        Stdio.print("url: \(run.htmlUrl.absoluteString)")
    }

    private func renderJob(_ job: WorkflowJob) {
        let status = job.conclusion ?? job.status
        Stdio.print("\(ANSI.bold("Job #\(job.id)")): \(job.name)")
        Stdio.print("status: \(conclusionGlyph(status)) \(status)")
        if let workflow = job.workflowName {
            Stdio.print("workflow: \(workflow)")
        }
        if let started = job.startedAt, let ended = job.completedAt {
            Stdio.print("duration: \(Self.formatDuration(ended.timeIntervalSince(started)))")
        }
        if let url = job.htmlUrl {
            Stdio.print("url: \(url.absoluteString)")
        }
        if let steps = job.steps, !steps.isEmpty {
            Stdio.print("")
            Stdio.print(ANSI.bold("Steps:"))
            for step in steps {
                let stepGlyph = conclusionGlyph(step.conclusion ?? step.status)
                Stdio.print("  \(stepGlyph) \(step.number). \(step.name)")
            }
        }
    }

    private func conclusionGlyph(_ value: String) -> String {
        switch value {
        case "success": return ANSI.green("✓")
        case "failure", "cancelled", "timed_out", "action_required":
            return ANSI.red("✗")
        case "skipped", "neutral", "stale": return ANSI.dim("-")
        case "in_progress", "queued", "pending", "waiting":
            return ANSI.yellow("…")
        default: return "?"
        }
    }

    private func enforceExit(_ conclusion: String?) throws {
        if conclusion != "success" {
            throw ExitCode(1)
        }
    }

    // MARK: Logs

    private func downloadAndPrintLogs(
        client: APIClient, slug: String, runId: Int, failedOnly: Bool
    ) async throws {
        let path = failedOnly
            ? "repos/\(slug)/actions/runs/\(runId)/attempts/latest/logs"
            : "repos/\(slug)/actions/runs/\(runId)/logs"
        // GitHub returns a 302 to a signed S3 URL. URLSession follows
        // redirects by default; the body we get back IS the zip.
        let response = try await client.raw(method: .get, path: path)
        guard !response.body.isEmpty else {
            Stdio.stderr.write(Data("No log archive returned (run still in progress?).\n".utf8))
            return
        }
        try await ZipExtractor.printConcatenatedTextEntries(zipData: response.body)
    }

    // MARK: Helpers

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m\(s % 60)s"
    }
}

/// Bundle for `--json` output: `WorkflowRun` plus optionally-fetched jobs.
struct RunWithJobs {
    let run: WorkflowRun
    let jobs: [WorkflowJob]
}

enum RunViewFields {
    static let map: [String: @Sendable (RunWithJobs) -> Any?] = [
        "attempt":            { $0.run.runAttempt },
        "conclusion":         { $0.run.conclusion },
        "createdAt":          { JSONFieldSelector.iso8601($0.run.createdAt) },
        "databaseId":         { $0.run.id },
        "displayTitle":       { $0.run.displayTitle },
        "event":              { $0.run.event },
        "headBranch":         { $0.run.headBranch },
        "headSha":            { $0.run.headSha },
        "jobs":               { $0.jobs.map(jobDict) },
        "name":               { $0.run.name },
        "number":             { $0.run.runNumber },
        "startedAt":          { $0.run.runStartedAt.map(JSONFieldSelector.iso8601) },
        "status":             { $0.run.status },
        "updatedAt":          { JSONFieldSelector.iso8601($0.run.updatedAt) },
        "url":                { $0.run.htmlUrl.absoluteString },
        "workflowDatabaseId": { $0.run.workflowId },
        "workflowName":       { $0.run.name },
    ]

    /// Per-job shape from `gh run view --json jobs`.
    static func jobDict(_ job: WorkflowJob) -> [String: Any] {
        [
            "completedAt": job.completedAt.map(JSONFieldSelector.iso8601) ?? NSNull(),
            "conclusion":  job.conclusion ?? "",
            "databaseId":  job.id,
            "name":        job.name,
            "startedAt":   job.startedAt.map(JSONFieldSelector.iso8601) ?? NSNull(),
            "status":      job.status,
            "steps":       (job.steps ?? []).map(stepDict),
            "url":         job.htmlUrl?.absoluteString ?? "",
        ]
    }

    /// Per-step shape from `gh run view --json jobs[].steps`.
    static func stepDict(_ step: WorkflowJobStep) -> [String: Any] {
        [
            "completedAt": step.completedAt.map(JSONFieldSelector.iso8601) ?? NSNull(),
            "conclusion":  step.conclusion ?? "",
            "name":        step.name,
            "number":      step.number,
            "startedAt":   step.startedAt.map(JSONFieldSelector.iso8601) ?? NSNull(),
            "status":      step.status,
        ]
    }
}
