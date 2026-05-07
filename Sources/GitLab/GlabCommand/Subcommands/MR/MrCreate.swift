import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct MrCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("t"), .long],
            help: "MR title.")
    var title: String

    @Option(name: [.customShort("d"), .long],
            help: "MR description.")
    var description: String?

    @Option(name: [.customShort("s"), .customLong("source-branch")],
            help: "Source branch (default: cwd's current branch).")
    var sourceBranch: String?

    @Option(name: [.customShort("b"), .customLong("target-branch")],
            help: "Target branch (default: project's default branch).")
    var targetBranch: String?

    @Option(name: [.customShort("l"), .customLong("label")],
            parsing: .singleValue,
            help: "Add a label; repeatable.")
    var labels: [String] = []

    @Option(name: [.customShort("a"), .long],
            parsing: .singleValue,
            help: "Assign a username; repeatable.")
    var assignees: [String] = []

    @Option(name: .customLong("reviewer"),
            parsing: .singleValue,
            help: "Add a reviewer by username; repeatable.")
    var reviewers: [String] = []

    @Option(name: [.customShort("m"), .customLong("milestone")],
            help: "Milestone IID.")
    var milestoneId: Int?

    @Flag(name: .long, help: "Mark as draft.")
    var draft: Bool = false

    @Flag(name: .customLong("squash"),
          help: "Set the 'squash on merge' flag.")
    var squash: Bool = false

    @Flag(name: .customLong("remove-source-branch"),
          help: "Set the 'remove source branch on merge' flag.")
    var removeSourceBranch: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    private struct CreateRequest: Encodable {
        let title: String
        let description: String?
        let sourceBranch: String
        let targetBranch: String?
        let labels: String?
        let assigneeIds: [Int]?
        let reviewerIds: [Int]?
        let milestoneId: Int?
        let removeSourceBranch: Bool?
        let squash: Bool?
    }

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let gitClient: any ForgeKit.GitClient = CommandContext.gitClient()

        let source: String
        if let sourceBranch, !sourceBranch.isEmpty {
            source = sourceBranch
        } else if let cwd = try? await gitClient.currentBranch(), !cwd.isEmpty {
            source = cwd
        } else {
            throw MrCreateError.noSourceBranch
        }

        var assigneeIds: [Int]? = nil
        if !assignees.isEmpty {
            assigneeIds = try await assignees.asyncMap { username in
                try await MrSupport.userIdLookup(client: client, username: username)
            }
        }

        var reviewerIds: [Int]? = nil
        if !reviewers.isEmpty {
            reviewerIds = try await reviewers.asyncMap { username in
                try await MrSupport.userIdLookup(client: client, username: username)
            }
        }

        let actualTitle = draft && !title.lowercased().hasPrefix("draft:")
            ? "Draft: \(title)"
            : title

        let request = CreateRequest(
            title: actualTitle,
            description: description,
            sourceBranch: source,
            targetBranch: targetBranch,
            labels: labels.isEmpty ? nil : labels.joined(separator: ","),
            assigneeIds: assigneeIds,
            reviewerIds: reviewerIds,
            milestoneId: milestoneId,
            removeSourceBranch: removeSourceBranch ? true : nil,
            squash: squash ? true : nil)

        let merge: MergeRequest = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/merge_requests",
            body: request)

        if json {
            Stdio.print(try CodableOutput.prettyJSON(merge))
            return
        }
        Stdio.print("Created !\(merge.iid): \(merge.title)")
        Stdio.print(merge.webUrl.absoluteString)
    }
}

enum MrCreateError: Error, LocalizedError {
    case noSourceBranch

    var errorDescription: String? {
        switch self {
        case .noSourceBranch:
            return "No source branch given and the current directory is not on a tracked branch. Pass --source-branch."
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
