import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct RepoList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List GitLab projects.",
        aliases: ["ls"]
    )

    @Option(name: [.customShort("h"), .customLong("hostname")],
            help: "Hostname to query (default: gitlab.com or $GITLAB_HOST).")
    var hostname: String?

    @Option(name: [.customShort("g"), .long],
            help: "List projects under a group / subgroup (full path).")
    var group: String?

    @Option(name: .long,
            help: "List projects under a user (username).")
    var user: String?

    @Flag(name: .customLong("owned"),
          help: "Limit to projects owned by the authenticated user.")
    var owned: Bool = false

    @Flag(name: .customLong("starred"),
          help: "Limit to projects starred by the authenticated user.")
    var starred: Bool = false

    @Flag(name: .customLong("membership"),
          help: "Limit to projects the authenticated user is a member of.")
    var membership: Bool = false

    @Option(name: .customLong("visibility"),
            help: "Filter by visibility: public / internal / private.")
    var visibility: String?

    @Option(name: [.customShort("s"), .long],
            help: "Search the project name and path.")
    var search: String?

    @Option(name: [.customShort("P"), .customLong("per-page")],
            help: "Items per page.")
    var perPage: Int = 30

    @Option(name: [.customShort("p"), .long],
            help: "Page number.")
    var page: Int = 1

    @Flag(name: .long, help: "Print as JSON array.")
    var json: Bool = false

    func run() async throws {
        let client = try await CommandContext.apiClient(host: hostname)

        let path: String
        if let group {
            // GitLab's group path also needs URL-encoding.
            let enc = group
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: "/", with: "%2F") ?? group
            path = "groups/\(enc)/projects"
        } else if let user {
            path = "users/\(user)/projects"
        } else {
            path = "projects"
        }

        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        if owned { query.append(URLQueryItem(name: "owned", value: "true")) }
        if starred { query.append(URLQueryItem(name: "starred", value: "true")) }
        if membership { query.append(URLQueryItem(name: "membership", value: "true")) }
        if let visibility {
            query.append(URLQueryItem(name: "visibility", value: visibility))
        }
        if let search {
            query.append(URLQueryItem(name: "search", value: search))
        }

        let projects: [Project] = try await client.get(path, query: query)

        if json {
            Stdio.print(try CodableOutput.prettyJSON(projects))
            return
        }
        if projects.isEmpty {
            Stdio.print("No projects match.")
            return
        }
        for p in projects {
            let archivedTag = (p.archived == true) ? "  " + ANSI.yellow("(archived)") : ""
            let branchTag = p.defaultBranch.map { "  " + ANSI.dim("[\($0)]") } ?? ""
            Stdio.print("#\(p.id)\t\(p.pathWithNamespace)\(branchTag)\(archivedTag)")
            if let d = p.description, !d.isEmpty {
                Stdio.print("\t\(ANSI.dim(d))")
            }
        }
    }
}
