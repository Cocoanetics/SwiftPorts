import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct MrView: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "view",
        abstract: "Display a merge request.",
        aliases: ["show"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    @Flag(name: [.customShort("w"), .long],
          help: "Open the MR in the default browser.")
    var web: Bool = false

    @Flag(name: [.customShort("c"), .long],
          help: "Show comments and activity.")
    var comments: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let merge: MergeRequest = try await client.get(
            "projects/\(target.encodedPath)/merge_requests/\(iid)")

        if web {
            try await Browser.open(merge.webUrl)
            Stdio.print("Opening \(merge.webUrl.absoluteString) in your browser.")
            return
        }

        let notes: [Note]? = comments
            ? try await client.get(
                "projects/\(target.encodedPath)/merge_requests/\(iid)/notes",
                query: [URLQueryItem(name: "sort", value: "asc")])
            : nil
        let userNotes = notes?.filter { !$0.system }

        if json {
            if let userNotes {
                Stdio.print(try CodableOutput.prettyJSON(
                    MergeRequestWithComments(merge: merge, comments: userNotes)))
            } else {
                Stdio.print(try CodableOutput.prettyJSON(merge))
            }
            return
        }

        let titleSuffix = (merge.draft == true || merge.workInProgress == true)
            ? "  " + ANSI.yellow("(draft)") : ""
        Stdio.print("\(ANSI.bold("!\(merge.iid)"))  \(ANSI.bold(merge.title))\(titleSuffix)")
        let stateLabel = MrSupport.renderState(merge.state)
        let authorBit = merge.author.map { "@\($0.username)" } ?? "—"
        Stdio.print("state: \(stateLabel)  author: \(authorBit)")
        Stdio.print("branches: \(merge.sourceBranch) → \(merge.targetBranch)")
        if let createdAt = merge.createdAt {
            Stdio.print("created: \(ISO8601DateFormatter().string(from: createdAt))")
        }
        if !merge.labels.isEmpty {
            Stdio.print("labels: \(merge.labels.joined(separator: ", "))")
        }
        if let milestone = merge.milestone {
            Stdio.print("milestone: \(milestone.title)")
        }
        if let assignees = merge.assignees, !assignees.isEmpty {
            Stdio.print("assignees: \(assignees.map { "@\($0.username)" }.joined(separator: ", "))")
        }
        if let reviewers = merge.reviewers, !reviewers.isEmpty {
            Stdio.print("reviewers: \(reviewers.map { "@\($0.username)" }.joined(separator: ", "))")
        }
        if let detail = merge.detailedMergeStatus {
            Stdio.print("merge status: \(detail)")
        }
        Stdio.print("url: \(merge.webUrl.absoluteString)")
        if let body = merge.description, !body.isEmpty {
            Stdio.print("\n--\n\(body)")
        }

        if let userNotes {
            guard !userNotes.isEmpty else {
                Stdio.print("\n(no comments)")
                return
            }
            Stdio.print("\n--- comments ---")
            for note in userNotes {
                let when = note.createdAt.map(ISO8601DateFormatter().string(from:)) ?? "?"
                Stdio.print("\n@\(note.author.username)  \(ANSI.dim(when))")
                Stdio.print(note.body)
            }
        }
    }
}

/// `--comments --json` flat shape: every MR field at the top level
/// plus a sibling `"comments"` array.
private struct MergeRequestWithComments: Encodable {
    let merge: MergeRequest
    let comments: [Note]

    private enum ExtraKeys: String, CodingKey { case comments }

    func encode(to encoder: Encoder) throws {
        try merge.encode(to: encoder)
        var container = encoder.container(keyedBy: ExtraKeys.self)
        try container.encode(comments, forKey: .comments)
    }
}
