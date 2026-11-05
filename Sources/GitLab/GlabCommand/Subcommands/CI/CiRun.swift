import ArgumentParser
import ShellKit
import Foundation
import ForgeKit
import GitLab

struct CiRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Trigger a new pipeline."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("b"), .long],
            help: "Branch or tag to run the pipeline against. Defaults to cwd branch.")
    var branch: String?

    @Option(name: [.customShort("v"), .customLong("variable")],
            parsing: .singleValue,
            help: "Pipeline variable in KEY=VALUE form; repeatable.")
    var variables: [String] = []

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let gitClient: any ForgeKit.GitClient = CommandContext.gitClient()
        let ref = try await CiSupport.pickRef(branch: branch, gitClient: gitClient)

        let parsedVars: [PipelineCreateRequest.Variable] = try variables.map { raw in
            guard let eq = raw.firstIndex(of: "=") else {
                throw CiRunError.malformedVariable(raw)
            }
            return PipelineCreateRequest.Variable(
                key: String(raw[..<eq]),
                value: String(raw[raw.index(after: eq)...]))
        }

        let pipeline = try await client.createPipeline(
            project: target,
            ref: ref,
            variables: parsedVars)
        Shell.print("Triggered #\(pipeline.id) on \(ref): \(CiSupport.renderStatus(pipeline.status))")
        Shell.print(pipeline.webUrl.absoluteString)
    }
}

enum CiRunError: Error, LocalizedError {
    case malformedVariable(String)

    var errorDescription: String? {
        switch self {
        case .malformedVariable(let s):
            return "Invalid --variable argument \"\(s)\". Expected KEY=VALUE."
        }
    }
}
