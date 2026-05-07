import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct MrUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    @Option(name: [.customShort("t"), .long], help: "New title.")
    var title: String?

    @Option(name: [.customShort("d"), .long],
            help: "New description.")
    var description: String?

    @Option(name: [.customShort("l"), .customLong("label")],
            parsing: .singleValue,
            help: "Add a label; repeatable.")
    var addLabels: [String] = []

    @Option(name: [.customShort("u"), .customLong("unlabel")],
            parsing: .singleValue,
            help: "Remove a label; repeatable.")
    var removeLabels: [String] = []

    @Option(name: [.customShort("a"), .long],
            parsing: .singleValue,
            help: "Replace assignees with these usernames; repeatable.")
    var assignees: [String] = []

    @Option(name: .customLong("reviewer"),
            parsing: .singleValue,
            help: "Replace reviewers with these usernames; repeatable.")
    var reviewers: [String] = []

    @Flag(name: .long, help: "Remove all assignees.")
    var unassign: Bool = false

    @Option(name: [.customShort("m"), .long],
            help: "Milestone IID. Pass 0 to clear.")
    var milestone: Int?

    @Option(name: [.customShort("b"), .customLong("target-branch")],
            help: "Change the target branch.")
    var targetBranch: String?

    @Flag(name: .long, help: "Mark as ready (clears the draft prefix).")
    var ready: Bool = false

    @Flag(name: .long, help: "Mark as draft.")
    var draft: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    private struct UpdateRequest: Encodable {
        var title: String?
        var description: String?
        var addLabels: String?
        var removeLabels: String?
        var assigneeIds: [Int]?
        var reviewerIds: [Int]?
        var milestoneId: Int?
        var targetBranch: String?
    }

    func run() async throws {
        if ready && draft {
            throw MrUpdateError.flagConflict("--ready and --draft are mutually exclusive.")
        }
        if unassign && !assignees.isEmpty {
            throw MrUpdateError.flagConflict("--assignee and --unassign are mutually exclusive.")
        }

        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        var request = UpdateRequest()
        if !addLabels.isEmpty { request.addLabels = addLabels.joined(separator: ",") }
        if !removeLabels.isEmpty { request.removeLabels = removeLabels.joined(separator: ",") }
        if let milestone { request.milestoneId = milestone }
        if let targetBranch { request.targetBranch = targetBranch }

        if unassign {
            request.assigneeIds = []
        } else if !assignees.isEmpty {
            request.assigneeIds = try await assignees.asyncMap { username in
                try await MrSupport.userIdLookup(client: client, username: username)
            }
        }
        if !reviewers.isEmpty {
            request.reviewerIds = try await reviewers.asyncMap { username in
                try await MrSupport.userIdLookup(client: client, username: username)
            }
        }

        // Title handling: --draft prefixes "Draft: ", --ready strips
        // a leading draft prefix. Both compose with an explicit
        // --title — `--title "Foo" --draft` becomes "Draft: Foo".
        var newTitle = title
        if ready || draft {
            var base: String
            if let t = newTitle {
                base = t
            } else {
                let current: MergeRequest = try await client.get(
                    "projects/\(target.encodedPath)/merge_requests/\(iid)")
                base = current.title
            }
            for prefix in ["Draft: ", "draft: ", "DRAFT: ", "WIP: ", "wip: "] {
                if base.hasPrefix(prefix) {
                    base = String(base.dropFirst(prefix.count))
                    break
                }
            }
            newTitle = ready ? base : "Draft: \(base)"
        }
        request.title = newTitle
        if let description { request.description = description }

        let updated: MergeRequest = try await client.send(
            method: .put,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)",
            body: request)

        if json {
            Stdio.print(try CodableOutput.prettyJSON(updated))
            return
        }
        Stdio.print("Updated !\(updated.iid): \(updated.title)")
        Stdio.print(updated.webUrl.absoluteString)
    }
}

enum MrUpdateError: Error, LocalizedError {
    case flagConflict(String)

    var errorDescription: String? {
        switch self {
        case .flagConflict(let m): return m
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            try await result.append(transform(element))
        }
        return result
    }
}
