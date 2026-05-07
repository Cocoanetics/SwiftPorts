import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct WorkflowRunDispatch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Trigger a workflow_dispatch event."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Argument(help: "Workflow ID or filename (e.g. ci.yml).")
    var workflow: String

    @Option(name: [.customShort("r"), .customLong("ref")],
            help: "Branch or tag to dispatch from (default: repo's default branch).")
    var ref: String?

    @Option(name: [.customShort("F"), .customLong("field")],
            parsing: .singleValue,
            help: "Workflow input as KEY=VALUE; repeatable.")
    var fields: [String] = []

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()

        let resolvedRef: String
        if let ref { resolvedRef = ref }
        else {
            let repo: Repository = try await client.get("repos/\(target.slug)")
            resolvedRef = repo.defaultBranch
        }

        var inputs: [String: String] = [:]
        for raw in fields {
            guard let eq = raw.firstIndex(of: "=") else {
                throw ValidationError("--field expects KEY=VALUE; got '\(raw)'")
            }
            inputs[String(raw[..<eq])] = String(raw[raw.index(after: eq)...])
        }

        struct Body: Codable {
            var ref: String
            var inputs: [String: String]?
        }
        try await client.send(
            method: .post,
            path: "repos/\(target.slug)/actions/workflows/\(workflow)/dispatches",
            body: Body(ref: resolvedRef, inputs: inputs.isEmpty ? nil : inputs))
        Stdio.print("\(ANSI.green("✓")) Dispatched workflow \(workflow) on \(resolvedRef)")
    }
}

struct WorkflowEnable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable a previously disabled workflow."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Argument(help: "Workflow ID or filename.") var workflow: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        _ = try await client.raw(
            method: .put,
            path: "repos/\(target.slug)/actions/workflows/\(workflow)/enable")
        Stdio.print("\(ANSI.green("✓")) Enabled \(workflow)")
    }
}

struct WorkflowDisable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable a workflow."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Argument(help: "Workflow ID or filename.") var workflow: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        _ = try await client.raw(
            method: .put,
            path: "repos/\(target.slug)/actions/workflows/\(workflow)/disable")
        Stdio.print("\(ANSI.green("✓")) Disabled \(workflow)")
    }
}
