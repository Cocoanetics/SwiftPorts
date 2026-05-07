import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct CiStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Live status of the latest pipeline on a branch."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("b"), .long],
            help: "Branch to watch. Defaults to the cwd's current branch.")
    var branch: String?

    @Option(name: .long,
            help: "Polling interval in seconds.")
    var pollInterval: Double = 2.0

    @Flag(name: .long,
          help: "Print one snapshot and exit (don't poll).")
    var once: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let gitClient: any ForgeKit.GitClient = CommandContext.gitClient()
        let ref = try await CiSupport.pickRef(branch: branch, gitClient: gitClient)

        while true {
            let pipeline: Pipeline = try await client.get(
                "projects/\(target.encodedPath)/pipelines/latest",
                query: [URLQueryItem(name: "ref", value: ref)])
            let jobs: [Job] = try await client.get(
                "projects/\(target.encodedPath)/pipelines/\(pipeline.id)/jobs",
                query: [URLQueryItem(name: "per_page", value: "100")])

            // \r + clear-line keeps the output to one tick if stdout
            // is a TTY. If not, just print successive lines.
            let summary = makeSummaryLine(pipeline: pipeline, jobs: jobs, ref: ref)
            if TTY.isStdoutColorEnabled {
                Stdio.print("\u{1B}[2K\r\(summary)", terminator: "")
                Stdio.stdout.write(Data())
            } else {
                Stdio.print(summary)
            }

            if once || pipeline.status.isTerminal {
                if TTY.isStdoutColorEnabled { Stdio.print() } // newline after final tick
                printJobBreakdown(jobs)
                if case .failed = pipeline.status { throw ExitCode(1) }
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func makeSummaryLine(
        pipeline: Pipeline, jobs: [Job], ref: String
    ) -> String {
        let counts = countsByStatus(jobs)
        var pieces = ["#\(pipeline.id)", CiSupport.renderStatus(pipeline.status), "ref: \(ref)"]
        if let running = counts[.running], running > 0 {
            pieces.append(ANSI.cyan("\(running) running"))
        }
        if let success = counts[.success], success > 0 {
            pieces.append(ANSI.green("\(success) ok"))
        }
        if let failed = counts[.failed], failed > 0 {
            pieces.append(ANSI.red("\(failed) failed"))
        }
        if let pending = counts[.pending], pending > 0 {
            pieces.append("\(pending) pending")
        }
        pieces.append(ANSI.dim(CiSupport.ageInWords(from: pipeline.startedAt ?? pipeline.createdAt)))
        return pieces.joined(separator: "  ")
    }

    private func countsByStatus(_ jobs: [Job]) -> [PipelineStatus: Int] {
        var out: [PipelineStatus: Int] = [:]
        for j in jobs { out[j.status, default: 0] += 1 }
        return out
    }

    private func printJobBreakdown(_ jobs: [Job]) {
        Stdio.print()
        CiView.printJobsByStage(jobs)
    }
}
