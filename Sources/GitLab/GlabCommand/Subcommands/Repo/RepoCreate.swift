import ArgumentParser
import Sandbox
import Foundation
import ForgeKit
import GitLab

struct RepoCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new GitLab project."
    )

    @Argument(help: "Project name (the URL slug). Path will be lowercased / hyphenated.")
    var name: String

    @Option(name: [.customShort("h"), .customLong("hostname")],
            help: "Hostname (default: gitlab.com or $GITLAB_HOST).")
    var hostname: String?

    @Option(name: [.customShort("g"), .long],
            help: "Create under this group (full path, e.g. `labs` or `labs/sub`).")
    var group: String?

    @Option(name: [.customShort("d"), .long],
            help: "Project description.")
    var description: String?

    @Option(name: .customLong("visibility"),
            help: "private / internal / public. Default: private.")
    var visibility: String = "private"

    @Option(name: .customLong("default-branch"),
            help: "Default branch for the new project.")
    var defaultBranch: String?

    @Flag(name: .customLong("issues"),
          inversion: .prefixedNo,
          exclusivity: .exclusive,
          help: "Enable / disable the issues feature.")
    var issuesEnabled: Bool = true

    @Flag(name: .customLong("merge-requests"),
          inversion: .prefixedNo,
          exclusivity: .exclusive,
          help: "Enable / disable merge requests.")
    var mergeRequestsEnabled: Bool = true

    @Flag(name: .customLong("wiki"),
          inversion: .prefixedNo,
          exclusivity: .exclusive,
          help: "Enable / disable the wiki.")
    var wikiEnabled: Bool = true

    @Flag(name: .long,
          help: "Initialise the repo with a README commit on the default branch.")
    var initializeWithReadme: Bool = false

    @Flag(name: .long, help: "Print as JSON.")
    var json: Bool = false

    private struct CreateRequest: Encodable {
        let name: String
        let path: String?
        let namespaceId: Int?
        let description: String?
        let visibility: String
        let defaultBranch: String?
        let issuesAccessLevel: String
        let mergeRequestsAccessLevel: String
        let wikiAccessLevel: String
        let initializeWithReadme: Bool?
    }

    func run() async throws {
        let client = try await CommandContext.apiClient(host: hostname)

        var namespaceId: Int? = nil
        if let group {
            namespaceId = try await Self.lookupGroupId(client: client, fullPath: group)
        }

        let request = CreateRequest(
            name: name,
            path: nil,
            namespaceId: namespaceId,
            description: description,
            visibility: visibility,
            defaultBranch: defaultBranch,
            issuesAccessLevel: issuesEnabled ? "enabled" : "disabled",
            mergeRequestsAccessLevel: mergeRequestsEnabled ? "enabled" : "disabled",
            wikiAccessLevel: wikiEnabled ? "enabled" : "disabled",
            initializeWithReadme: initializeWithReadme ? true : nil)

        let project: Project = try await client.send(
            method: .post, path: "projects", body: request)

        if json {
            Stdio.print(try CodableOutput.prettyJSON(project))
            return
        }
        Stdio.print("\(ANSI.green("✓")) Created \(ANSI.bold(project.pathWithNamespace))")
        Stdio.print("  web:  \(project.webUrl.absoluteString)")
        if let ssh = project.sshUrlToRepo { Stdio.print("  ssh:  \(ssh.absoluteString)") }
        if let http = project.httpUrlToRepo { Stdio.print("  http: \(http.absoluteString)") }
    }

    static func lookupGroupId(client: APIClient, fullPath: String) async throws -> Int {
        // GitLab accepts either the encoded full path or the numeric
        // ID for `GET /groups/:id`. Encode the path's slashes.
        let enc = fullPath
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
            .replacingOccurrences(of: "/", with: "%2F") ?? fullPath
        let group: Group = try await client.get("groups/\(enc)")
        return group.id
    }
}
