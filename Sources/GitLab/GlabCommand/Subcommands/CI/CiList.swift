import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct CiList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List recent CI/CD pipelines.",
        aliases: ["ls"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("s"), .long],
            help: "Filter by status (running / success / failed / canceled / pending / …).")
    var status: String?

    @Option(name: .long,
            help: "Filter by ref (branch or tag).")
    var ref: String?

    @Option(name: .long,
            help: "Filter by source (push, schedule, web, api, trigger, …).")
    var source: String?

    @Option(name: [.customShort("P"), .customLong("per-page")],
            help: "Items per page.")
    var perPage: Int = 30

    @Option(name: [.customShort("p"), .long],
            help: "Page number.")
    var page: Int = 1

    @Flag(name: .long, help: "Print as JSON array.")
    var json: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let ref { query.append(URLQueryItem(name: "ref", value: ref)) }
        if let source { query.append(URLQueryItem(name: "source", value: source)) }

        let pipelines: [Pipeline] = try await client.get(
            "projects/\(target.encodedPath)/pipelines", query: query)

        if json {
            Stdio.print(try CodableOutput.prettyJSON(pipelines))
            return
        }
        if pipelines.isEmpty {
            Stdio.print("No pipelines match.")
            return
        }
        for p in pipelines {
            let age = CiSupport.ageInWords(from: p.createdAt)
            let refLabel = p.ref ?? "—"
            let sha = String(p.sha.prefix(8))
            Stdio.print("#\(p.id)\t\(CiSupport.renderStatus(p.status))\t\(refLabel)\t\(sha)\t\(age)")
        }
    }
}
