import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct VariableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variable",
        abstract: "Manage Actions / Codespaces / Dependabot variables.",
        subcommands: [VariableList.self, VariableSet.self, VariableGet.self, VariableDelete.self]
    )
}

private struct ActionsVariable: Codable, Sendable {
    let name: String
    let value: String
    let createdAt: Date
    let updatedAt: Date
}

private struct ActionsVariableList: Codable, Sendable {
    let totalCount: Int
    let variables: [ActionsVariable]
}

private func variablesPath(repo: RepositoryReference, scope: String) -> String {
    switch scope {
    case "actions": return "repos/\(repo.slug)/actions/variables"
    case "codespaces": return "repos/\(repo.slug)/codespaces/variables"
    case "dependabot": return "repos/\(repo.slug)/dependabot/variables"
    default: return "repos/\(repo.slug)/actions/variables"
    }
}

struct VariableList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List repository variables."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Option(name: .customLong("scope"),
            help: "actions (default), codespaces, dependabot")
    var scope: String = "actions"

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let envelope: ActionsVariableList = try await client.get(
            variablesPath(repo: target, scope: scope))
        if envelope.variables.isEmpty {
            Stdio.print("No \(scope) variables in \(target.slug)."); return
        }
        for v in envelope.variables {
            Stdio.print("\(v.name)\t\(v.value)")
        }
    }
}

struct VariableGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Print one variable's value."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Option(name: .customLong("scope")) var scope: String = "actions"
    @Argument(help: "Variable name.") var name: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let v: ActionsVariable = try await client.get(
            "\(variablesPath(repo: target, scope: scope))/\(name)")
        Stdio.print(v.value)
    }
}

struct VariableSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set (create or update) a variable."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Option(name: .customLong("scope")) var scope: String = "actions"
    @Argument(help: "Variable name.") var name: String
    @Option(name: [.short, .customLong("body")],
            help: "Value (use - for stdin).")
    var value: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let actualValue: String
        if value == "-" {
            let data = Stdio.stdin.readDataToEndOfFile()
            actualValue = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } else {
            actualValue = value
        }
        let client = try await CommandContext.apiClient()
        // Try create first; if it 422s with already-exists, fall back to PATCH.
        struct CreateBody: Codable { var name: String; var value: String }
        struct PatchBody: Codable { var name: String?; var value: String }
        let basePath = variablesPath(repo: target, scope: scope)
        do {
            try await client.send(
                method: .post,
                path: basePath,
                body: CreateBody(name: name, value: actualValue))
            Stdio.print("\(ANSI.green("✓")) Created variable \(name)")
        } catch APIError.http(_, _, _) {
            // Update existing
            try await client.send(
                method: .patch,
                path: "\(basePath)/\(name)",
                body: PatchBody(name: nil, value: actualValue))
            Stdio.print("\(ANSI.green("✓")) Updated variable \(name)")
        }
    }
}

struct VariableDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a variable."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Option(name: .customLong("scope")) var scope: String = "actions"
    @Argument(help: "Variable name.") var name: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        try await client.delete(
            "\(variablesPath(repo: target, scope: scope))/\(name)")
        Stdio.print("\(ANSI.green("✓")) Deleted variable \(name)")
    }
}
