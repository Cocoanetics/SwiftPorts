import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct ReleaseList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List releases."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("limit")])
    var limit: Int = 30

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let releases: [Release] = try await client.get(
            "projects/\(target.encodedPath)/releases",
            query: [URLQueryItem(name: "per_page", value: String(min(limit, 100)))])
        if releases.isEmpty { Stdio.print("No releases in \(target.fullPath)."); return }
        let formatter = ISO8601DateFormatter()
        for r in releases.prefix(limit) {
            let when = r.releasedAt.map { formatter.string(from: $0) } ?? ""
            let title = r.name ?? r.tagName
            Stdio.print("\(r.tagName)\t\(title)\t\(when)")
        }
    }
}
