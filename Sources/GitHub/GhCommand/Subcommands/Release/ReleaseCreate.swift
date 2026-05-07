import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct ReleaseCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new release."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Tag name (e.g. v1.2.3).")
    var tag: String

    @Option(name: [.short, .customLong("title")], help: "Release title.")
    var title: String?

    @Option(name: [.customLong("notes")],
            help: "Release notes. Use - to read from stdin.")
    var notes: String?

    @Option(name: [.customLong("target")],
            help: "Target commitish (branch or SHA).")
    var target: String?

    @Flag(name: .long, help: "Mark as draft (not visible until published).")
    var draft: Bool = false

    @Flag(name: .long, help: "Mark as prerelease.")
    var prerelease: Bool = false

    @Flag(name: .customLong("generate-notes"),
          help: "Auto-generate release notes from PRs since the last release.")
    var generateNotes: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let notesValue: String?
        if notes == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            notesValue = String(data: data, encoding: .utf8)
        } else {
            notesValue = notes
        }
        let request = ReleaseCreateRequest(
            tagName: tag,
            name: title,
            body: notesValue,
            draft: draft ? true : nil,
            prerelease: prerelease ? true : nil,
            targetCommitish: self.target,
            generateReleaseNotes: generateNotes ? true : nil
        )
        let client = try await CommandContext.apiClient()
        let release: Release = try await client.send(
            method: .post,
            path: "repos/\(target.slug)/releases",
            body: request)

        Stdio.print("Created release \(release.tagName)\(release.draft ? " (draft)" : "")")
        Stdio.print(release.htmlUrl.absoluteString)
    }
}
