import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct LabelList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the labels in a project."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("limit")])
    var limit: Int = 100

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let labels: [Label] = try await client.get(
            "projects/\(target.encodedPath)/labels",
            query: [URLQueryItem(name: "per_page", value: String(min(limit, 100)))])
        let trimmed = Array(labels.prefix(limit))

        if json {
            Stdio.print(try CodableOutput.prettyJSON(trimmed))
            return
        }
        if trimmed.isEmpty {
            Stdio.print("No labels in \(target.fullPath).")
            return
        }
        for l in trimmed {
            let desc = l.description ?? ""
            Stdio.print("\(l.name)\t#\(l.color)\t\(desc)")
        }
    }
}
