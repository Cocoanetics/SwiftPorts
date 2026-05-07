import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ReleaseView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "View information about a release.",
        discussion: "Without TAG, the latest non-draft, non-prerelease is shown."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Tag name. Omit for the latest release.")
    var tag: String?

    @Option(name: .long,
            help: "Output JSON with the specified fields (comma-separated).")
    var json: String?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let path = tag.map { "repos/\(target.slug)/releases/tags/\($0)" }
            ?? "repos/\(target.slug)/releases/latest"
        let release: Release = try await client.get(path)

        if let json {
            let fields = try JSONFieldSelector.parse(raw: json, fieldMap: ReleaseFields.map)
            let latestTag: String?
            if fields.contains("isLatest") {
                latestTag = await ReleaseList.latestReleaseTag(client: client, slug: target.slug)
            } else {
                latestTag = nil
            }
            let context = ReleaseFields.Context(release: release, latestTag: latestTag)
            Stdio.print(try JSONFieldSelector.render(item: context, fields: fields, fieldMap: ReleaseFields.map))
            return
        }

        Stdio.print("\(release.tagName)  \(release.name ?? "")")
        if let when = release.publishedAt {
            Stdio.print("published: \(ISO8601DateFormatter().string(from: when))")
        }
        Stdio.print("author: @\(release.author.login)")
        Stdio.print("url: \(release.htmlUrl.absoluteString)")
        if !release.assets.isEmpty {
            Stdio.print("\nassets:")
            for a in release.assets {
                let size = ByteCountFormatter.string(
                    fromByteCount: a.size, countStyle: .file)
                Stdio.print("  \(a.name)  (\(size))  \(a.browserDownloadUrl.absoluteString)")
            }
        }
        if let body = release.body, !body.isEmpty {
            Stdio.print("\n--\n\(body)")
        }
    }
}
