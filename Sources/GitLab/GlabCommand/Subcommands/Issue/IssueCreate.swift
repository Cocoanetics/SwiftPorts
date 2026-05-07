import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct IssueCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create an issue."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("t"), .long],
            help: "Issue title.")
    var title: String

    @Option(name: [.customShort("d"), .long],
            help: "Issue description / body.")
    var description: String?

    @Option(name: [.customShort("l"), .customLong("label")],
            parsing: .singleValue,
            help: "Add a label; repeatable.")
    var labels: [String] = []

    @Option(name: [.customShort("a"), .long],
            parsing: .singleValue,
            help: "Assign a user by username; repeatable.")
    var assignees: [String] = []

    @Option(name: [.customShort("m"), .long],
            help: "Milestone IID.")
    var milestone: Int?

    @Flag(name: [.customShort("C"), .long],
          help: "Mark the issue as confidential.")
    var confidential: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    private struct CreateRequest: Encodable {
        let title: String
        let description: String?
        let labels: String?
        let confidential: Bool?
        let milestoneId: Int?
        let assigneeIds: [Int]?
    }

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        var assigneeIds: [Int]? = nil
        if !assignees.isEmpty {
            assigneeIds = try await assignees.asyncMap { username in
                try await Self.userIdLookup(client: client, username: username)
            }
        }

        let request = CreateRequest(
            title: title,
            description: description,
            labels: labels.isEmpty ? nil : labels.joined(separator: ","),
            confidential: confidential ? true : nil,
            milestoneId: milestone,
            assigneeIds: assigneeIds)

        let path = "projects/\(target.encodedPath)/issues"
        let issue: Issue = try await client.send(method: .post, path: path, body: request)

        if json {
            Stdio.print(try CodableOutput.prettyJSON(issue))
            return
        }
        Stdio.print("Created #\(issue.iid): \(issue.title)")
        Stdio.print(issue.webUrl.absoluteString)
    }

    private static func userIdLookup(client: APIClient, username: String) async throws -> Int {
        let users: [User] = try await client.get(
            "users", query: [URLQueryItem(name: "username", value: username)])
        guard let id = users.first?.id else {
            throw IssueCreateError.userNotFound(username)
        }
        return id
    }
}

enum IssueCreateError: Error, LocalizedError {
    case userNotFound(String)

    var errorDescription: String? {
        switch self {
        case .userNotFound(let u): return "No user found with username \"\(u)\"."
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
