import ArgumentParser
import Sandbox
import Foundation
import GitHub

struct GistList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List your gists."
    )

    @Option(name: [.short, .customLong("limit")],
            help: "Maximum gists to fetch.")
    var limit: Int = 30

    @Flag(name: .long, help: "Only show public gists.")
    var publicOnly: Bool = false

    @Flag(name: .long, help: "Only show secret gists.")
    var secretOnly: Bool = false

    func run() async throws {
        let client = try await CommandContext.apiClient()
        let perPage = min(limit, 100)
        let gists: [Gist] = try await client.get(
            "gists",
            query: [URLQueryItem(name: "per_page", value: String(perPage))])
        let filtered = gists.filter { gist in
            if publicOnly { return gist.public }
            if secretOnly { return !gist.public }
            return true
        }
        let trimmed = Array(filtered.prefix(limit))

        if trimmed.isEmpty {
            Stdio.print("No gists found.")
            return
        }
        for g in trimmed {
            let visibility = g.public ? "public" : "secret"
            let files = g.files.keys.sorted().joined(separator: ", ")
            let desc = g.description ?? ""
            Stdio.print("\(g.id)\t\(visibility)\t\(files)\t\(desc)")
        }
    }
}
