import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct MrNote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Comment on a merge request.",
        aliases: ["comment"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    @Option(name: [.customShort("m"), .long],
            help: "Comment body.")
    var message: String

    private struct CreateNote: Encodable { let body: String }

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let note: Note = try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)/notes",
            body: CreateNote(body: message))
        Stdio.print("Posted note \(note.id) on !\(iid).")
    }
}

struct MrSubscribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subscribe",
        abstract: "Subscribe to a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    private struct Empty: Encodable {}

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)/subscribe",
            body: Empty())
        Stdio.print("Subscribed to !\(iid).")
    }
}

struct MrUnsubscribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unsubscribe",
        abstract: "Unsubscribe from a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    private struct Empty: Encodable {}

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)/unsubscribe",
            body: Empty())
        Stdio.print("Unsubscribed from !\(iid).")
    }
}

struct MrDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        try await client.delete(
            "projects/\(target.encodedPath)/merge_requests/\(iid)")
        Stdio.print("Deleted !\(iid).")
    }
}
