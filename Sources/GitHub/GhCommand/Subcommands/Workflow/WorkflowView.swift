import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct WorkflowView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "View a workflow."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Workflow ID, or filename (e.g. ci.yml).")
    var workflow: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let workflow: Workflow = try await client.get(
            "repos/\(target.slug)/actions/workflows/\(workflow)")

        Stdio.print("\(workflow.name)  (#\(workflow.id))")
        Stdio.print("state: \(workflow.state.rawValue)")
        Stdio.print("path: \(workflow.path)")
        Stdio.print("url: \(workflow.htmlUrl.absoluteString)")
    }
}
