import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct IssueUpdate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update an issue."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Issue IID, `#IID`, or full issue URL.")
    var issue: String

    @Option(name: [.customShort("t"), .long], help: "New title.")
    var title: String?

    @Option(name: [.customShort("d"), .long],
            help: "New description (replaces the current body).")
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
            help: "Replace assignees with these usernames. Mutually exclusive with --unassign.")
    var assignees: [String] = []

    @Flag(name: .long, help: "Remove all assignees.")
    var unassign: Bool = false

    @Option(name: [.customShort("m"), .long],
            help: "Milestone IID. Pass 0 to clear.")
    var milestone: Int?

    @Flag(name: [.customShort("C"), .long],
          help: "Mark the issue confidential.")
    var confidential: Bool = false

    @Flag(name: [.customShort("p"), .long],
          help: "Mark the issue public (clears confidential flag).")
    var publicFlag: Bool = false

    @Flag(name: .customLong("lock-discussion"),
          help: "Lock the issue's discussion.")
    var lockDiscussion: Bool = false

    @Flag(name: .customLong("unlock-discussion"),
          help: "Unlock the issue's discussion.")
    var unlockDiscussion: Bool = false

    @Option(name: [.customShort("w"), .long], help: "Issue weight.")
    var weight: Int?

    @Option(name: .customLong("due-date"),
            help: "Due date as YYYY-MM-DD. Empty string clears it.")
    var dueDate: String?

    @Flag(name: .long, help: "Print the updated issue as JSON.")
    var json: Bool = false

    private struct UpdateRequest: Encodable {
        var title: String?
        var description: String?
        var addLabels: String?
        var removeLabels: String?
        var assigneeIds: [Int]?
        var milestoneId: Int?
        var confidential: Bool?
        var discussionLocked: Bool?
        var weight: Int?
        var dueDate: String?
    }

    func run() async throws {
        if unassign && !assignees.isEmpty {
            throw IssueUpdateError.flagConflict(
                "--assignee and --unassign are mutually exclusive.")
        }
        if confidential && publicFlag {
            throw IssueUpdateError.flagConflict(
                "--confidential and --public are mutually exclusive.")
        }
        if lockDiscussion && unlockDiscussion {
            throw IssueUpdateError.flagConflict(
                "--lock-discussion and --unlock-discussion are mutually exclusive.")
        }

        let parsed = try IssueArgument.parse(issue)
        let target: RepositoryReference
        if let fromURL = parsed.repoFromURL {
            target = fromURL
        } else {
            target = try await CommandContext.resolveRepo(flag: repo)
        }
        let client = try await CommandContext.apiClient(host: target.host)

        var request = UpdateRequest()
        request.title = title
        request.description = description
        if !addLabels.isEmpty {
            request.addLabels = addLabels.joined(separator: ",")
        }
        if !removeLabels.isEmpty {
            request.removeLabels = removeLabels.joined(separator: ",")
        }
        if let milestone {
            request.milestoneId = milestone
        }
        if confidential { request.confidential = true }
        if publicFlag { request.confidential = false }
        if lockDiscussion { request.discussionLocked = true }
        if unlockDiscussion { request.discussionLocked = false }
        if let weight {
            guard weight >= 0 else {
                throw IssueUpdateError.invalidValue("weight must be ≥ 0.")
            }
            request.weight = weight
        }
        if let dueDate {
            request.dueDate = dueDate
        }
        if unassign {
            request.assigneeIds = []
        } else if !assignees.isEmpty {
            request.assigneeIds = try await assignees.asyncMap { username in
                try await Self.userIdLookup(client: client, username: username)
            }
        }

        let path = "projects/\(target.encodedPath)/issues/\(parsed.iid)"
        let updated: Issue = try await client.send(
            method: .put, path: path, body: request)

        if json {
            Stdio.print(try CodableOutput.prettyJSON(updated))
            return
        }
        Stdio.print("Updated #\(updated.iid): \(updated.title)")
        Stdio.print(updated.webUrl.absoluteString)
    }

    private static func userIdLookup(client: APIClient, username: String) async throws -> Int {
        let users: [User] = try await client.get(
            "users", query: [URLQueryItem(name: "username", value: username)])
        guard let id = users.first?.id else {
            throw IssueUpdateError.userNotFound(username)
        }
        return id
    }
}

enum IssueUpdateError: Error, LocalizedError {
    case flagConflict(String)
    case invalidValue(String)
    case userNotFound(String)

    var errorDescription: String? {
        switch self {
        case .flagConflict(let m), .invalidValue(let m):
            return m
        case .userNotFound(let u):
            return "No user found with username \"\(u)\"."
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
