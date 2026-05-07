import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct RunCancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancel an in-progress workflow run."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Argument(help: "Run ID.") var id: Int

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        _ = try await client.raw(
            method: .post,
            path: "repos/\(target.slug)/actions/runs/\(id)/cancel")
        Stdio.print("\(ANSI.green("✓")) Cancelled run \(id)")
    }
}

struct RunRerun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rerun",
        abstract: "Rerun a workflow run."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Argument(help: "Run ID.") var id: Int
    @Flag(name: .customLong("failed"),
          help: "Rerun only the failed jobs.")
    var failedOnly: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let suffix = failedOnly ? "/rerun-failed-jobs" : "/rerun"
        _ = try await client.raw(
            method: .post,
            path: "repos/\(target.slug)/actions/runs/\(id)\(suffix)")
        Stdio.print("\(ANSI.green("✓")) Re-queued run \(id)\(failedOnly ? " (failed jobs only)" : "")")
    }
}

struct RunDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a workflow run."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Argument(help: "Run ID.") var id: Int
    @Flag(name: [.short, .customLong("yes")]) var skipPrompt: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        if !skipPrompt {
            Stdio.stderr.write(Data("Delete run \(id) in \(target.slug)? [y/N] ".utf8))
            let line = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard line == "y" || line == "yes" else { throw ExitCode(1) }
        }
        let client = try await CommandContext.apiClient()
        try await client.delete("repos/\(target.slug)/actions/runs/\(id)")
        Stdio.print("\(ANSI.green("✓")) Deleted run \(id)")
    }
}
