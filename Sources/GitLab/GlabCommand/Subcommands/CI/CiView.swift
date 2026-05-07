import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct CiView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Show a pipeline with its jobs grouped by stage.",
        aliases: ["show"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Pipeline ID. Defaults to the latest pipeline for the resolved branch.")
    var pipelineId: Int?

    @Option(name: [.customShort("b"), .long],
            help: "Branch to look up the latest pipeline for. Defaults to the cwd's current branch.")
    var branch: String?

    @Flag(name: [.customShort("w"), .long],
          help: "Open the pipeline in your browser.")
    var web: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let gitClient: any ForgeKit.GitClient = CommandContext.gitClient()

        let id = try await CiSupport.resolvePipelineId(
            explicit: pipelineId,
            repo: target,
            client: client,
            branch: branch,
            gitClient: gitClient)

        let pipeline: Pipeline = try await client.get(
            "projects/\(target.encodedPath)/pipelines/\(id)")

        if web {
            try await Browser.open(pipeline.webUrl)
            Stdio.print("Opening \(pipeline.webUrl.absoluteString) in your browser.")
            return
        }

        let jobs: [Job] = try await client.get(
            "projects/\(target.encodedPath)/pipelines/\(id)/jobs",
            query: [URLQueryItem(name: "per_page", value: "100")])

        if json {
            struct PipelineWithJobs: Encodable {
                let pipeline: Pipeline
                let jobs: [Job]
            }
            Stdio.print(try CodableOutput.prettyJSON(
                PipelineWithJobs(pipeline: pipeline, jobs: jobs)))
            return
        }

        Self.printPipelineHeader(pipeline)
        Self.printJobsByStage(jobs)
    }

    static func printPipelineHeader(_ p: Pipeline) {
        Stdio.print("\(ANSI.bold("#\(p.id)"))  \(CiSupport.renderStatus(p.status))")
        Stdio.print("ref: \(p.ref ?? "—")  sha: \(String(p.sha.prefix(8)))")
        Stdio.print("started: \(CiSupport.ageInWords(from: p.startedAt ?? p.createdAt))  duration: \(CiSupport.formatDuration(p.duration))")
        Stdio.print("url: \(p.webUrl.absoluteString)")
    }

    static func printJobsByStage(_ jobs: [Job]) {
        // Preserve first-seen stage order (the API returns jobs roughly
        // in stage order, sometimes interleaved by retry).
        var stageOrder: [String] = []
        var byStage: [String: [Job]] = [:]
        for j in jobs {
            if byStage[j.stage] == nil { stageOrder.append(j.stage) }
            byStage[j.stage, default: []].append(j)
        }
        for stage in stageOrder {
            Stdio.print("\n\(ANSI.bold("[\(stage)]"))")
            for j in byStage[stage] ?? [] {
                let dur = CiSupport.formatDuration(j.duration)
                Stdio.print("  \(CiSupport.renderStatus(j.status))  \(j.name) \(ANSI.dim("(#\(j.id), \(dur))"))")
            }
        }
    }
}
