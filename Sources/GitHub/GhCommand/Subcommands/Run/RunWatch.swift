import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct RunWatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Poll a workflow run until it terminates."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Run ID.")
    var id: Int

    @Option(name: [.short, .customLong("interval")],
            help: "Polling interval in seconds.")
    var interval: Int = 5

    @Flag(name: .customLong("exit-status"),
          help: "After the run finishes, exit non-zero if conclusion != 'success'.")
    var exitStatus: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()

        var lastStatus: String?
        let pollInterval = max(1, interval)

        while true {
            let run: WorkflowRun = try await client.get(
                "repos/\(target.slug)/actions/runs/\(id)")
            let status = run.status ?? "?"
            if status != lastStatus {
                let stamp = ISO8601DateFormatter().string(from: Date())
                Stdio.print("[\(stamp)] \(status)")
                lastStatus = status
            }
            if status == "completed" {
                let conclusion = run.conclusion ?? "?"
                let glyph: String = {
                    switch conclusion {
                    case "success": return ANSI.green("✓")
                    case "failure", "cancelled", "timed_out": return ANSI.red("✗")
                    case "skipped", "neutral": return ANSI.dim("-")
                    default: return "?"
                    }
                }()
                Stdio.print("\(glyph) Run #\(run.runNumber) finished: \(conclusion)")
                if exitStatus, conclusion != "success" {
                    throw ExitCode(1)
                }
                return
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }
}
