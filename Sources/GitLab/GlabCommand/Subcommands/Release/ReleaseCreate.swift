import ArgumentParser
import Foundation
import GitLab
import Sandbox

struct ReleaseCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a release pointing at <tag>."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: .long,
            help: "Release name (defaults to the tag name).")
    var name: String?

    @Option(name: [.customShort("F"), .customLong("notes-file")],
            help: "Release notes from a file. Use - for stdin.")
    var notesFile: String?

    @Option(name: [.customShort("n"), .customLong("notes")],
            help: "Inline release notes.")
    var notes: String?

    @Option(name: [.customShort("r"), .customLong("ref")],
            help: "Ref to tag if the tag doesn't already exist (defaults to default branch).")
    var ref: String?

    @Argument(help: "Tag name (e.g. `v1.0.0`).")
    var tagName: String

    private struct Body: Encodable {
        let tagName: String
        let name: String?
        let description: String?
        let ref: String?
    }

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        let resolvedNotes: String?
        if let path = notesFile {
            if path == "-" {
                resolvedNotes = String(decoding: Stdio.stdin.availableData,
                                       as: UTF8.self)
            } else {
                let url = Sandbox.resolve(path)
                try await Sandbox.authorize(url)
                resolvedNotes = try String(contentsOf: url, encoding: .utf8)
            }
        } else {
            resolvedNotes = notes
        }

        let body = Body(tagName: tagName, name: name,
                        description: resolvedNotes, ref: ref)
        let release: Release = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/releases",
            body: body)
        Stdio.print("Created release \(release.tagName)")
        if let url = release._links?.selfLink {
            Stdio.print(url.absoluteString)
        }
    }
}
