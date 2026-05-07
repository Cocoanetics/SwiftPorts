import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct MrMerge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge a merge request.",
        aliases: ["accept"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    @Option(name: .long, help: "Custom merge commit message.")
    var mergeCommitMessage: String?

    @Option(name: .long, help: "Custom squash commit message.")
    var squashCommitMessage: String?

    @Flag(name: [.customShort("s"), .customLong("squash")],
          help: "Squash all commits before merging.")
    var squash: Bool = false

    @Flag(name: [.customShort("d"), .customLong("remove-source-branch")],
          help: "Remove the source branch after merging.")
    var removeSourceBranch: Bool = false

    @Flag(name: .customLong("when-pipeline-succeeds"),
          help: "Merge automatically when the head pipeline succeeds.")
    var whenPipelineSucceeds: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    private struct MergeRequestPayload: Encodable {
        let mergeCommitMessage: String?
        let squashCommitMessage: String?
        let shouldRemoveSourceBranch: Bool?
        let mergeWhenPipelineSucceeds: Bool?
        let squash: Bool?
    }

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let payload = MergeRequestPayload(
            mergeCommitMessage: mergeCommitMessage,
            squashCommitMessage: squashCommitMessage,
            shouldRemoveSourceBranch: removeSourceBranch ? true : nil,
            mergeWhenPipelineSucceeds: whenPipelineSucceeds ? true : nil,
            squash: squash ? true : nil)
        let merged: MergeRequest = try await client.send(
            method: .put,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)/merge",
            body: payload)
        if json {
            Stdio.print(try CodableOutput.prettyJSON(merged))
            return
        }
        Stdio.print("Merged !\(merged.iid): \(merged.title)")
        if let sha = merged.mergeCommitSha {
            Stdio.print("merge commit: \(sha)")
        }
        Stdio.print(merged.webUrl.absoluteString)
    }
}
