import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct RepoEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit repository metadata."
    )

    @Option(name: [.short, .long],
            help: "Repository as OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: RepositoryReference?

    @Option(name: [.customLong("description")],
            help: "Repository description (use empty string to clear).")
    var description: String?

    @Option(name: .customLong("homepage"), help: "Project homepage URL.")
    var homepage: String?

    @Option(name: .customLong("default-branch"),
            help: "Set the default branch (must already exist).")
    var defaultBranch: String?

    @Option(name: .customLong("visibility"),
            help: "Visibility: public, private, internal.")
    var visibility: Visibility?

    @Flag(name: .customLong("enable-issues"))
    var enableIssues: Bool = false
    @Flag(name: .customLong("disable-issues"))
    var disableIssues: Bool = false
    @Flag(name: .customLong("enable-wiki"))
    var enableWiki: Bool = false
    @Flag(name: .customLong("disable-wiki"))
    var disableWiki: Bool = false
    @Flag(name: .customLong("enable-projects"))
    var enableProjects: Bool = false
    @Flag(name: .customLong("disable-projects"))
    var disableProjects: Bool = false
    @Flag(name: .customLong("delete-branch-on-merge"))
    var deleteBranchOnMerge: Bool = false
    @Flag(name: .customLong("no-delete-branch-on-merge"))
    var noDeleteBranchOnMerge: Bool = false

    func run() async throws {
        let target = try await RepositoryResolver.resolve(flag: repo)
        let request = RepoUpdateRequest(
            description: description,
            homepage: homepage,
            visibility: visibility,
            hasIssues: triState(enableIssues, disableIssues),
            hasProjects: triState(enableProjects, disableProjects),
            hasWiki: triState(enableWiki, disableWiki),
            defaultBranch: defaultBranch,
            deleteBranchOnMerge: triState(deleteBranchOnMerge, noDeleteBranchOnMerge))
        let client = try await CommandContext.apiClient()
        let updated: Repository = try await client.send(
            method: .patch,
            path: "repos/\(target.slug)",
            body: request)
        Stdio.print("\(ANSI.green("✓")) Edited \(updated.fullName)")
    }

    private func triState(_ on: Bool, _ off: Bool) -> Bool? {
        if on && off { return nil }
        if on { return true }
        if off { return false }
        return nil
    }
}

extension Visibility: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}
