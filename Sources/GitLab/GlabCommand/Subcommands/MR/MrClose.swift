import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct MrClose: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    private struct StateUpdate: Encodable { let stateEvent: String }

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let updated: MergeRequest = try await client.send(
            method: .put,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)",
            body: StateUpdate(stateEvent: "close"))
        Stdio.print("Closed !\(updated.iid): \(updated.title)")
    }
}

struct MrReopen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reopen",
        abstract: "Reopen a closed merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    private struct StateUpdate: Encodable { let stateEvent: String }

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let updated: MergeRequest = try await client.send(
            method: .put,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)",
            body: StateUpdate(stateEvent: "reopen"))
        Stdio.print("Reopened !\(updated.iid): \(updated.title)")
    }
}
