import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct SecretCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret",
        abstract: "Manage Actions / Codespaces / Dependabot secrets.",
        discussion: """
        `gh secret list` and `gh secret delete` are supported.
        `gh secret set` is intentionally not yet implemented — setting a
        secret requires libsodium SealedBox encryption against the
        repo's public key, which adds a C dependency we haven't taken
        yet. Coming soon.
        """,
        subcommands: [SecretList.self, SecretDelete.self]
    )
}

private struct ActionsSecret: Codable, Sendable {
    let name: String
    let createdAt: Date
    let updatedAt: Date
}

private struct ActionsSecretList: Codable, Sendable {
    let totalCount: Int
    let secrets: [ActionsSecret]
}

private func secretsPath(repo: RepositoryReference, scope: String) -> String {
    switch scope {
    case "actions": return "repos/\(repo.slug)/actions/secrets"
    case "codespaces": return "repos/\(repo.slug)/codespaces/secrets"
    case "dependabot": return "repos/\(repo.slug)/dependabot/secrets"
    default: return "repos/\(repo.slug)/actions/secrets"
    }
}

struct SecretList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List secret names (values are write-only)."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Option(name: .customLong("scope")) var scope: String = "actions"

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let envelope: ActionsSecretList = try await client.get(
            secretsPath(repo: target, scope: scope))
        if envelope.secrets.isEmpty {
            Stdio.print("No \(scope) secrets in \(target.slug)."); return
        }
        for s in envelope.secrets {
            let when = ISO8601DateFormatter().string(from: s.updatedAt)
            Stdio.print("\(s.name)\tupdated \(when)")
        }
    }
}

struct SecretDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a secret."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Option(name: .customLong("scope")) var scope: String = "actions"
    @Argument(help: "Secret name.") var name: String

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        try await client.delete("\(secretsPath(repo: target, scope: scope))/\(name)")
        Stdio.print("\(ANSI.green("✓")) Deleted secret \(name)")
    }
}
