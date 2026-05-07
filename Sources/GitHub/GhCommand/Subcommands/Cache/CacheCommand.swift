import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct CacheCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache",
        abstract: "List and delete Actions caches.",
        subcommands: [CacheList.self, CacheDelete.self]
    )
}

private struct ActionsCache: Codable, Sendable {
    let id: Int
    let ref: String
    let key: String
    let version: String?
    let lastAccessedAt: Date
    let createdAt: Date
    let sizeInBytes: Int64
}

private struct ActionsCachesEnvelope: Codable, Sendable {
    let totalCount: Int
    let actionsCaches: [ActionsCache]
}

struct CacheList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List Actions caches in a repository."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Option(name: [.short, .customLong("limit")]) var limit: Int = 30

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        let envelope: ActionsCachesEnvelope = try await client.get(
            "repos/\(target.slug)/actions/caches",
            query: [URLQueryItem(name: "per_page", value: String(min(limit, 100)))])
        if envelope.actionsCaches.isEmpty {
            Stdio.print("No caches in \(target.slug)."); return
        }
        for c in envelope.actionsCaches.prefix(limit) {
            let size = ByteCountFormatter.string(
                fromByteCount: c.sizeInBytes, countStyle: .file)
            let when = ISO8601DateFormatter().string(from: c.lastAccessedAt)
            Stdio.print("\(c.id)\t\(size)\t\(c.ref)\t\(when)\t\(c.key)")
        }
    }
}

struct CacheDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an Actions cache by ID or by key."
    )
    @Option(name: [.short, .long]) var repo: RepositoryReference?
    @Option(name: .customLong("key"),
            help: "Delete every cache matching this key (instead of by ID).")
    var key: String?
    @Option(name: .customLong("ref"),
            help: "Restrict --key match to this ref (e.g. refs/heads/main).")
    var ref: String?
    @Argument(help: "Cache ID.") var id: Int?

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let client = try await CommandContext.apiClient()
        if let id {
            try await client.delete("repos/\(target.slug)/actions/caches/\(id)")
            Stdio.print("\(ANSI.green("✓")) Deleted cache \(id)")
            return
        }
        guard let key else {
            throw ValidationError("Provide a cache ID or --key.")
        }
        var query = [URLQueryItem(name: "key", value: key)]
        if let ref { query.append(URLQueryItem(name: "ref", value: ref)) }
        let response = try await client.raw(
            method: .delete,
            path: "repos/\(target.slug)/actions/caches",
            query: query)
        _ = response  // server returns the deleted IDs in the body
        Stdio.print("\(ANSI.green("✓")) Deleted caches matching key='\(key)'")
    }
}
