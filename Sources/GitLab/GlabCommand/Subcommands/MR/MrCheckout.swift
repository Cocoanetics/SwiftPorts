import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct MrCheckout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkout",
        abstract: "Fetch and check out the source branch of a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    @Option(name: [.customShort("b"), .long],
            help: "Local branch name to use (default: the MR's source branch).")
    var localBranch: String?

    @Option(name: [.customShort("r"), .long],
            help: "Remote name to fetch from (default: origin).")
    var remote: String = "origin"

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let merge: MergeRequest = try await client.get(
            "projects/\(target.encodedPath)/merge_requests/\(iid)")

        let local = localBranch ?? merge.sourceBranch
        let mrRef = "refs/merge-requests/\(merge.iid)/head"
        let refspec = "\(mrRef):\(local)"

        let git: any ForgeKit.GitClient = CommandContext.gitClient()
        Stdio.print("Fetching \(remote) \(refspec) …")
        try await git.fetch(remote: remote, refspec: refspec)
        Stdio.print("Checking out \(local) …")
        try await git.checkout(ref: local)
        Stdio.print("\(ANSI.green("✓")) On !\(merge.iid) (\(merge.sourceBranch) → \(merge.targetBranch))")
    }
}
