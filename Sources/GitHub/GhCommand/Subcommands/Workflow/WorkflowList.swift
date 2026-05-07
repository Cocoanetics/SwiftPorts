import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct WorkflowList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the workflows in a repository."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("limit")], help: "Maximum workflows to fetch.")
    var limit: Int = 50

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let envelope: WorkflowListResponse = try await client.get(
            "repos/\(target.slug)/actions/workflows",
            query: [URLQueryItem(name: "per_page", value: String(min(limit, 100)))])

        let trimmed = Array(envelope.workflows.prefix(limit))
        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: WorkflowFields.list)
            Stdio.print(try JSONFieldSelector.render(items: trimmed, fields: fields, fieldMap: WorkflowFields.list))
            return
        }
        if trimmed.isEmpty {
            Stdio.print("No workflows in \(target.slug).")
            return
        }
        for w in trimmed {
            Stdio.print("\(w.id)\t\(w.state.rawValue)\t\(w.name)\t\(w.path)")
        }
    }
}

enum WorkflowFields {
    /// Fields exposed by `gh workflow list --json`.
    static let list: [String: @Sendable (Workflow) -> Any?] = [
        "id":    { $0.id },
        "name":  { $0.name },
        "path":  { $0.path },
        "state": { $0.state.rawValue },
    ]
}
