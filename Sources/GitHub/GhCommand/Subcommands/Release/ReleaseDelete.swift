import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ReleaseDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a release."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Tag name of the release to delete.")
    var tag: String

    @Flag(name: .long, help: "Also delete the underlying git tag.")
    var cleanupTag: Bool = false

    @Flag(name: [.short, .customLong("yes")],
          help: "Skip confirmation prompt.")
    var skipPrompt: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()

        if !skipPrompt {
            Stdio.stderr.write(Data(
                "Delete release \(tag) in \(target.slug)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else {
                Stdio.print("Aborted.")
                throw ExitCode(1)
            }
        }

        let release = try await findRelease(slug: target.slug, tag: tag, client: client)
        try await client.delete("repos/\(target.slug)/releases/\(release.id)")
        Stdio.print("✓ Deleted release \(tag)")

        if cleanupTag {
            try await client.delete("repos/\(target.slug)/git/refs/tags/\(tag)")
            Stdio.print("✓ Deleted git tag \(tag)")
        }
    }

    /// Look up a release by tag, falling back to a list scan for
    /// draft releases (whose tag may not be a real git ref yet).
    private func findRelease(
        slug: String,
        tag: String,
        client: APIClient
    ) async throws -> Release {
        do {
            return try await client.get("repos/\(slug)/releases/tags/\(tag)")
        } catch APIError.notFound {
            let all: [Release] = try await client.get(
                "repos/\(slug)/releases",
                query: [URLQueryItem(name: "per_page", value: "100")])
            if let match = all.first(where: { $0.tagName == tag }) {
                return match
            }
            throw APIError.notFound(
                url: URL(string: "https://api.github.com/repos/\(slug)/releases/tags/\(tag)")!)
        }
    }
}
