import ArgumentParser
import Sandbox
import Foundation
import GitHub
import ForgeKit

struct ProjectCopy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy a ProjectV2 (optionally to a different owner)."
    )

    @Argument(help: "Source project number.") var number: Int
    @Option(name: [.customShort("o"), .customLong("owner")],
            help: "Source owner login. Omit for your own.")
    var owner: String?
    @Flag(name: [.long, .customLong("org")]) var asOrg: Bool = false

    @Option(name: .customLong("target-owner"),
            help: "Login of the destination owner (default: same as source).")
    var targetOwner: String?
    @Flag(name: .customLong("target-org"),
          help: "Treat --target-owner as an organization.")
    var targetIsOrg: Bool = false

    @Option(name: [.short, .customLong("title")], help: "Title for the new project.")
    var title: String

    @Flag(name: .customLong("drafts"),
          help: "Include draft items in the copy (default: skip).")
    var includeDrafts: Bool = false

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let sourceOwner = ownerKind(owner: owner, asOrg: asOrg)
        let projectId = try await ProjectIDs.projectID(
            owner: sourceOwner, number: number, gql: gql)

        let target: ProjectIDs.Owner
        if let targetOwner {
            target = targetIsOrg ? .organization(targetOwner) : .user(targetOwner)
        } else {
            target = sourceOwner
        }
        let targetOwnerID = try await ProjectIDs.ownerID(target, gql: gql)

        let response: CopyProjectResponse = try await gql.query(
            ProjectMutations.copyProject,
            variables: [
                "projectId": .string(projectId),
                "targetOwnerId": .string(targetOwnerID),
                "title": .string(title),
                "includeDraftIssues": .bool(includeDrafts),
            ])
        let p = response.copyProjectV2.projectV2
        Stdio.print("\(ANSI.green("✓")) Copied → #\(p.number): \(p.title)")
        Stdio.print(p.url.absoluteString)
    }
}

struct ProjectMarkTemplate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mark-template",
        abstract: "Mark a project as a template (or unmark with --undo)."
    )
    @Argument(help: "Project number.") var number: Int
    @Option(name: [.customShort("o"), .customLong("owner")]) var owner: String?
    @Flag(name: [.long, .customLong("org")]) var asOrg: Bool = false
    @Flag(name: .customLong("undo"), help: "Unmark instead.") var undo: Bool = false

    func run() async throws {
        let gql = try await CommandContext.graphQLClient()
        let id = try await ProjectIDs.projectID(
            owner: ownerKind(owner: owner, asOrg: asOrg),
            number: number, gql: gql)

        if undo {
            let response: UnmarkProjectAsTemplateResponse = try await gql.query(
                ProjectMutations.unmarkProjectAsTemplate,
                variables: ["projectId": .string(id)])
            guard let s = response.unmarkProjectV2AsTemplate?.projectV2 else {
                throw silentRejection("unmark template", number: number)
            }
            Stdio.print("\(ANSI.green("✓")) Unmarked #\(number) as template (template=\(s.template))")
        } else {
            let response: MarkProjectAsTemplateResponse = try await gql.query(
                ProjectMutations.markProjectAsTemplate,
                variables: ["projectId": .string(id)])
            guard let s = response.markProjectV2AsTemplate?.projectV2 else {
                throw silentRejection("mark as template", number: number)
            }
            Stdio.print("\(ANSI.green("✓")) Marked #\(number) as template (template=\(s.template))")
        }
    }
}

/// GitHub returns 200 with a null payload when a project mutation is
/// silently rejected (typically: only valid on org-owned projects, or
/// the caller lacks admin). Surface a clearer message than 'no value'.
func silentRejection(_ what: String, number: Int) -> ValidationError {
    ValidationError(
        "GitHub returned no result for \(what) on project #\(number). " +
        "This usually means the operation isn't permitted for this " +
        "project (e.g. only valid on org-owned projects, or you lack admin).")
}

struct ProjectLink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Link a project to a repository (or team)."
    )
    @Argument(help: "Project number.") var number: Int
    @Option(name: [.customShort("o"), .customLong("owner")]) var owner: String?
    @Flag(name: [.long, .customLong("org")]) var asOrg: Bool = false
    @Option(name: .customLong("repo"),
            help: "Target repository as OWNER/NAME.")
    var repo: RepositoryReference?
    @Option(name: .customLong("team"),
            help: "Target team slug (requires --team-org).")
    var team: String?
    @Option(name: .customLong("team-org"),
            help: "Org login the team belongs to.")
    var teamOrg: String?

    func run() async throws {
        try await runLink(
            number: number,
            owner: owner, asOrg: asOrg,
            repo: repo, team: team, teamOrg: teamOrg,
            unlink: false)
    }
}

struct ProjectUnlink: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlink",
        abstract: "Unlink a project from a repository (or team)."
    )
    @Argument(help: "Project number.") var number: Int
    @Option(name: [.customShort("o"), .customLong("owner")]) var owner: String?
    @Flag(name: [.long, .customLong("org")]) var asOrg: Bool = false
    @Option(name: .customLong("repo")) var repo: RepositoryReference?
    @Option(name: .customLong("team")) var team: String?
    @Option(name: .customLong("team-org")) var teamOrg: String?

    func run() async throws {
        try await runLink(
            number: number,
            owner: owner, asOrg: asOrg,
            repo: repo, team: team, teamOrg: teamOrg,
            unlink: true)
    }
}

private func runLink(
    number: Int,
    owner: String?, asOrg: Bool,
    repo: RepositoryReference?, team: String?, teamOrg: String?,
    unlink: Bool
) async throws {
    let gql = try await CommandContext.graphQLClient()
    let projectId = try await ProjectIDs.projectID(
        owner: ownerKind(owner: owner, asOrg: asOrg),
        number: number, gql: gql)

    if let repo {
        let repositoryId = try await ProjectIDs.repositoryID(ref: repo, gql: gql)
        if unlink {
            let response: UnlinkProjectFromRepositoryResponse = try await gql.query(
                ProjectMutations.unlinkProjectFromRepository,
                variables: [
                    "projectId": .string(projectId),
                    "repositoryId": .string(repositoryId),
                ])
            guard response.unlinkProjectV2FromRepository != nil else {
                throw silentRejection("unlink from \(repo.slug)", number: number)
            }
            Stdio.print("\(ANSI.green("✓")) Unlinked #\(number) from \(repo.slug)")
        } else {
            let response: LinkProjectToRepositoryResponse = try await gql.query(
                ProjectMutations.linkProjectToRepository,
                variables: [
                    "projectId": .string(projectId),
                    "repositoryId": .string(repositoryId),
                ])
            guard response.linkProjectV2ToRepository != nil else {
                throw silentRejection("link to \(repo.slug)", number: number)
            }
            Stdio.print("\(ANSI.green("✓")) Linked #\(number) to \(repo.slug)")
        }
    } else if let team, let teamOrg {
        let teamId = try await ProjectIDs.teamID(org: teamOrg, slug: team, gql: gql)
        if unlink {
            let response: UnlinkProjectFromTeamResponse = try await gql.query(
                ProjectMutations.unlinkProjectFromTeam,
                variables: [
                    "projectId": .string(projectId),
                    "teamId": .string(teamId),
                ])
            guard response.unlinkProjectV2FromTeam != nil else {
                throw silentRejection("unlink from \(teamOrg)/\(team)", number: number)
            }
            Stdio.print("\(ANSI.green("✓")) Unlinked #\(number) from team \(teamOrg)/\(team)")
        } else {
            let response: LinkProjectToTeamResponse = try await gql.query(
                ProjectMutations.linkProjectToTeam,
                variables: [
                    "projectId": .string(projectId),
                    "teamId": .string(teamId),
                ])
            guard response.linkProjectV2ToTeam != nil else {
                throw silentRejection("link to \(teamOrg)/\(team)", number: number)
            }
            Stdio.print("\(ANSI.green("✓")) Linked #\(number) to team \(teamOrg)/\(team)")
        }
    } else {
        throw ValidationError("Pass --repo OWNER/NAME or --team SLUG --team-org ORG.")
    }
}
