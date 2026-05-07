import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct CiTrace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trace",
        abstract: "Stream a CI/CD job log in real time."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Argument(help: "Job ID (number) or job name (matched against the latest pipeline on the resolved branch).")
    var job: String

    @Option(name: [.customShort("b"), .long],
            help: "Branch to look up the latest pipeline for when matching by job name. Defaults to cwd branch.")
    var branch: String?

    @Option(name: .long,
            help: "Polling interval in seconds while the job is running.")
    var pollInterval: Double = 2.0

    @Flag(name: .long, help: "Don't stream — print whatever's buffered right now and exit.")
    var noFollow: Bool = false

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        let gitClient: any ForgeKit.GitClient = CommandContext.gitClient()

        var current = try await CiSupport.resolveJob(
            argument: job, repo: target, client: client,
            branch: branch, gitClient: gitClient)

        let header = "==> #\(current.id)  \(current.name) (\(current.stage))  \(CiSupport.renderStatus(current.status))"
        Stdio.stderr.write(Data((header + "\n").utf8))

        var offset = 0
        while true {
            offset += try await streamChunk(
                jobId: current.id, repo: target, client: client, fromOffset: offset)
            if noFollow { return }

            // Re-fetch the job to see if it's done.
            current = try await client.get(
                "projects/\(target.encodedPath)/jobs/\(current.id)")
            if current.status.isTerminal {
                // Drain any final tail bytes the previous fetch missed.
                offset += try await streamChunk(
                    jobId: current.id, repo: target, client: client, fromOffset: offset)
                let footer = "\n==> Job finished: \(CiSupport.renderStatus(current.status))" +
                    "  duration: \(CiSupport.formatDuration(current.duration))"
                Stdio.stderr.write(Data((footer + "\n").utf8))
                if case .failed = current.status { throw ExitCode(1) }
                return
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Fetch the job's trace and write only the bytes past
    /// `fromOffset` to stdout. Returns the number of new bytes
    /// written.
    ///
    /// GitLab's `/jobs/:id/trace` endpoint always returns the whole
    /// log; it ignores `Range:` requests. So we re-fetch every poll
    /// and slice out only the tail we haven't printed yet — matching
    /// upstream `glab ci trace`'s approach.
    private func streamChunk(
        jobId: Int,
        repo: RepositoryReference,
        client: APIClient,
        fromOffset: Int
    ) async throws -> Int {
        let response = try await client.raw(
            method: .get,
            path: "projects/\(repo.encodedPath)/jobs/\(jobId)/trace")
        let data = response.body
        guard data.count > fromOffset else { return 0 }
        let new = data.subdata(in: fromOffset..<data.count)
        Stdio.stdout.write(new)
        return new.count
    }
}
