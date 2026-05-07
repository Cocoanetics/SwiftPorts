import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct MrApprove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Approve a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    private struct EmptyBody: Encodable {}

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)/approve",
            body: EmptyBody())
        // Re-fetch approvals to surface counts.
        let approvals: MergeRequestApprovals = try await client.get(
            "projects/\(target.encodedPath)/merge_requests/\(iid)/approvals")
        let count = approvals.approvedBy?.count ?? 0
        let needed = approvals.approvalsLeft.map { "\($0) more needed" } ?? "—"
        Stdio.print("\(ANSI.green("✓")) Approved !\(iid). Approvals: \(count); \(needed).")
    }
}

struct MrUnapprove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unapprove",
        abstract: "Revoke your approval of a merge request.",
        aliases: ["revoke"]
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    private struct EmptyBody: Encodable {}

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        try await client.send(
            method: .post,
            path: "projects/\(target.encodedPath)/merge_requests/\(iid)/unapprove",
            body: EmptyBody())
        Stdio.print("\(ANSI.yellow("✓")) Unapproved !\(iid).")
    }
}
