import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct TagCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a tag at a given ref."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("m"), .customLong("message")],
            help: "Annotation message — present makes the tag annotated.")
    var message: String?

    @Argument(help: "Tag name (e.g. `v1.0.0`).")
    var tagName: String

    @Argument(help: "Ref to tag. Defaults to the default branch.")
    var ref: String?

    private struct Body: Encodable {
        let tagName: String
        let ref: String?
        let message: String?
    }

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let body = Body(tagName: tagName, ref: ref ?? "HEAD", message: message)
        let tag: Tag = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/repository/tags",
            body: body)
        Stdio.print("Created tag \(tag.name)")
    }
}
