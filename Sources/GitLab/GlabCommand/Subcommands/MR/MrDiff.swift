import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct MrDiff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Show the diff of a merge request."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "MR IID, `!IID`, `#IID`, or full URL.")
    var mr: String

    @Flag(name: [.customShort("w"), .long],
          help: "Open the MR diff in your browser instead of printing.")
    var web: Bool = false

    @Flag(name: .long, help: "Print as JSON (one entry per file).")
    var json: Bool = false

    func run() async throws {
        let (target, iid) = try await MrSupport.resolveTarget(
            argument: mr, explicitRepo: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        if web {
            let merge: MergeRequest = try await client.get(
                "projects/\(target.encodedPath)/merge_requests/\(iid)")
            let diffURL = merge.webUrl.appendingPathComponent("diffs")
            try await Browser.open(diffURL)
            Stdio.print("Opening \(diffURL.absoluteString).")
            return
        }

        let changes: MergeRequestChanges = try await client.get(
            "projects/\(target.encodedPath)/merge_requests/\(iid)/changes")

        if json {
            Stdio.print(try CodableOutput.prettyJSON(changes.changes))
            return
        }

        for change in changes.changes {
            let header: String
            switch true {
            case change.newFile:
                header = ANSI.green("+++ \(change.newPath) (new file)")
            case change.deletedFile:
                header = ANSI.red("--- \(change.oldPath) (deleted)")
            case change.renamedFile:
                header = ANSI.yellow("=== \(change.oldPath) → \(change.newPath) (renamed)")
            default:
                header = ANSI.bold("=== \(change.newPath)")
            }
            Stdio.print(header)
            Stdio.print(colorizeDiff(change.diff))
            Stdio.print()
        }
    }

    /// Minimal unified-diff colouring: green for additions, red for
    /// removals, cyan for hunk markers.
    private func colorizeDiff(_ raw: String) -> String {
        guard ANSI.enabled else { return raw }
        var out = ""
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                out += ANSI.green(String(line)) + "\n"
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                out += ANSI.red(String(line)) + "\n"
            } else if line.hasPrefix("@@") {
                out += ANSI.cyan(String(line)) + "\n"
            } else {
                out += String(line) + "\n"
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }
}
