import ArgumentParser
import Sandbox
import Foundation
import GitLab

struct RepoEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit project metadata."
    )

    @Option(name: [.customShort("R"), .long],
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: .customLong("description"),
            help: "Project description (use empty string to clear).")
    var description: String?

    @Option(name: .customLong("default-branch"),
            help: "Set the default branch (must already exist).")
    var defaultBranch: String?

    @Option(name: .customLong("visibility"),
            help: "Visibility: public, internal, private.")
    var visibility: String?

    @Flag(name: .customLong("enable-issues"))
    var enableIssues: Bool = false
    @Flag(name: .customLong("disable-issues"))
    var disableIssues: Bool = false
    @Flag(name: .customLong("enable-mrs"))
    var enableMRs: Bool = false
    @Flag(name: .customLong("disable-mrs"))
    var disableMRs: Bool = false
    @Flag(name: .customLong("enable-wiki"))
    var enableWiki: Bool = false
    @Flag(name: .customLong("disable-wiki"))
    var disableWiki: Bool = false
    @Flag(name: .customLong("enable-snippets"))
    var enableSnippets: Bool = false
    @Flag(name: .customLong("disable-snippets"))
    var disableSnippets: Bool = false

    private struct Body: Encodable {
        let description: String?
        let defaultBranch: String?
        let visibility: String?
        let issuesAccessLevel: String?
        let mergeRequestsAccessLevel: String?
        let wikiAccessLevel: String?
        let snippetsAccessLevel: String?
    }

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)

        // GitLab toggles features via *_access_level rather than booleans.
        // "enabled" turns the feature on; "disabled" turns it off; nil
        // leaves it untouched.
        let body = Body(
            description: description,
            defaultBranch: defaultBranch,
            visibility: visibility,
            issuesAccessLevel: triState(enableIssues, disableIssues),
            mergeRequestsAccessLevel: triState(enableMRs, disableMRs),
            wikiAccessLevel: triState(enableWiki, disableWiki),
            snippetsAccessLevel: triState(enableSnippets, disableSnippets))

        let updated: Project = try await client.send(
            method: .put,
            path: "projects/\(target.encodedPath)",
            body: body)
        Stdio.print("Edited \(updated.pathWithNamespace)")
    }

    private func triState(_ on: Bool, _ off: Bool) -> String? {
        if on && off { return nil }
        if on { return "enabled" }
        if off { return "disabled" }
        return nil
    }
}
