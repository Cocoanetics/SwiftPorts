import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ReleaseList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List releases in a repository."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.short, .customLong("limit")],
            help: "Maximum number of releases to fetch.")
    var limit: Int = 30

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let perPage = min(limit, 100)
        let releases: [Release] = try await client.get(
            "repos/\(target.slug)/releases",
            query: [URLQueryItem(name: "per_page", value: String(perPage))]
        )
        let trimmed = Array(releases.prefix(limit))

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: ReleaseFields.map)
            // `isLatest` requires the latest-release tag — fetch only
            // when actually requested to avoid the extra round trip.
            let latestTag: String?
            if fields.contains("isLatest") {
                latestTag = await Self.latestReleaseTag(client: client, slug: target.slug)
            } else {
                latestTag = nil
            }
            let contexts = trimmed.map {
                ReleaseFields.Context(release: $0, latestTag: latestTag)
            }
            Stdio.print(try JSONFieldSelector.render(items: contexts, fields: fields, fieldMap: ReleaseFields.map))
            return
        }

        if trimmed.isEmpty {
            Stdio.print("No releases found in \(target.slug).")
            return
        }
        for r in trimmed {
            let label = r.draft ? "[draft]" : (r.prerelease ? "[pre]" : "       ")
            let when = r.publishedAt.map(ISO8601DateFormatter().string(from:)) ?? "-"
            Stdio.print("\(label)  \(r.tagName)\t\(r.name ?? "")\t\(when)")
        }
    }

    /// Resolve the repo's latest non-draft, non-prerelease tag.
    /// Swallows errors (returns nil) since `isLatest` defaults to false.
    static func latestReleaseTag(client: APIClient, slug: String) async -> String? {
        do {
            let release: Release = try await client.get("repos/\(slug)/releases/latest")
            return release.tagName
        } catch {
            return nil
        }
    }
}
