import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct OrgCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "org",
        abstract: "Manage organizations.",
        subcommands: [OrgList.self]
    )
}

struct OrgList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List organizations you belong to."
    )

    @Option(name: [.short, .customLong("limit")]) var limit: Int = 100

    func run() async throws {
        let client = try await CommandContext.apiClient()
        struct Org: Codable, Sendable, Identifiable {
            let id: Int
            let login: String
            let description: String?
            let url: URL
        }
        let orgs: [Org] = try await client.get(
            "user/orgs",
            query: [URLQueryItem(name: "per_page", value: String(min(limit, 100)))])
        if orgs.isEmpty { Stdio.print("Not a member of any organizations."); return }
        for o in orgs.prefix(limit) {
            let desc = o.description ?? ""
            Stdio.print("\(o.login)\t\(desc)")
        }
    }
}
