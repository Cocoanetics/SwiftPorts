import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct CiRetry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retry",
        abstract: "Retry a failed pipeline (every failed job inside it)."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Pipeline ID. Defaults to the latest pipeline for the resolved branch.")
    var pipelineId: Int?

    @Option(name: [.customShort("b"), .long],
            help: "Branch when looking up the latest pipeline. Defaults to cwd branch.")
    var branch: String?

    private struct Empty: Encodable {}

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
        let pipeline: Pipeline = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/pipelines/\(id)/retry",
            body: Empty())
        Stdio.print("Retried #\(pipeline.id): \(CiSupport.renderStatus(pipeline.status))")
        Stdio.print(pipeline.webUrl.absoluteString)
    }
}
