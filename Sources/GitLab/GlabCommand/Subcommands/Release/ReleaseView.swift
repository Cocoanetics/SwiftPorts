import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct ReleaseView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Show details of a single release."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Tag name (e.g. `v1.0.0`).")
    var tagName: String

    @Flag(name: .long, help: "Print the JSON response body.")
    var json: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let encoded = tagName.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? tagName
        let release: Release = try await client.get(
            "projects/\(target.encodedPath)/releases/\(encoded)")
        if json {
            Stdio.print(try CodableOutput.prettyJSON(release))
            return
        }

        Stdio.print(release.name ?? release.tagName)
        Stdio.print("tag: \(release.tagName)")
        if let when = release.releasedAt {
            Stdio.print("released: \(ISO8601DateFormatter().string(from: when))")
        }
        if let author = release.author {
            Stdio.print("author: @\(author.username)")
        }
        if let body = release.description, !body.isEmpty {
            Stdio.print("\n\(body)")
        }
        if let links = release.assets?.links, !links.isEmpty {
            Stdio.print("\nassets:")
            for link in links { Stdio.print("  \(link.name): \(link.url.absoluteString)") }
        }
    }
}
