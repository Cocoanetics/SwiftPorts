import ArgumentParser
import ShellKit
import Foundation
import GitHub

struct ReleaseEdit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a release",
        discussion: """
            Examples:
              # Publish a release that was previously a draft
              $ gh release edit v1.0 --draft=false

              # Update the release notes from the content of a file
              $ gh release edit v1.0 --notes-file /path/to/release_notes.md
            """
    )

    @Option(name: [.customShort("R", allowingJoined: true), .long], parsing: .unconditional,
            help: "Repository as [HOST/]OWNER/REPO. Defaults to the current directory's git remote.")
    var repo: ReleaseEditRepo?

    @Argument(help: "Tag name of the release to edit.")
    var tag: String

    @Option(name: .customLong("draft"),
            help: "Save the release as a draft instead of publishing it")
    var draft: ReleaseEditBool?

    @Option(name: .customLong("prerelease"), help: "Mark the release as a prerelease")
    var prerelease: ReleaseEditBool?

    @Option(name: .customLong("latest"), help: "Explicitly mark the release as \"Latest\"")
    var latest: ReleaseEditBool?

    // String options consume the next word whatever it looks like, as
    // pflag does: `--notes '- Fixed a bug'` is notes, not a flag.
    @Option(name: [.customShort("n", allowingJoined: true), .customLong("notes")],
            parsing: .unconditional, help: "Release notes")
    var notes: String?

    @Option(name: [.customShort("t", allowingJoined: true), .customLong("title")],
            parsing: .unconditional, help: "Release title")
    var title: String?

    @Option(name: .customLong("discussion-category"), parsing: .unconditional,
            help: "Start a discussion in the specified category when publishing a draft")
    var discussionCategory: String?

    @Option(name: .customLong("target"), parsing: .unconditional,
            help: "Target branch or full commit SHA (default [main branch])")
    var target: String?

    @Option(name: .customLong("tag"), parsing: .unconditional, help: "The name of the tag")
    var newTag: String?

    @Option(name: [.customShort("F", allowingJoined: true), .customLong("notes-file")],
            parsing: .unconditional,
            help: "Read release notes from file (use \"-\" to read from standard input)")
    var notesFile: String?

    @Option(name: .customLong("verify-tag"),
            help: "Abort in case the git tag doesn't already exist in the remote repository")
    var verifyTag: ReleaseEditBool?

    func run() async throws {
        try requireFlags()
        let target = try await RepositoryResolver.resolve(flag: repo?.reference)
        let api = try await CommandContext.apiClient(host: repo?.host)
        let gql = try await CommandContext.graphQLClient(host: repo?.host)
        try await run(target: target, api: api, gql: gql)
    }

    func run(target: RepositoryReference, api: APIClient, gql: GraphQLClient) async throws {
        try requireFlags()
        var body = notes
        // Upstream reads a non-empty --notes-file before any network
        // call, and it replaces --notes outright.
        if let notesFile, !notesFile.isEmpty {
            body = try await Self.readNotesFile(notesFile)
        }

        let release = try await ReleaseLookup.fetchRelease(
            tag: tag, target: target, api: api, gql: gql)

        if verifyTag?.value == true, let newTag, !newTag.isEmpty {
            let present = try await ReleaseLookup.remoteTagExists(
                tag: newTag, target: target, gql: gql)
            if !present {
                throw ReleaseEditError.tagNotFound(tag: newTag, repo: target.slug)
            }
        }

        let request = makeRequest(body: body, currentTagName: release.tagName)
        let path = await ReleaseLookup.url(
            ["repos", target.owner, target.name, "releases", String(release.id)], api: api)
        let edited: Release = try await api.send(method: .patch, path: path, body: request)
        Shell.print(edited.htmlUrl.absoluteString)
    }

    /// Upstream `getParams`: only flags the caller set become keys.
    /// `tag_name` is always sent, because omitting it makes the API
    /// drop the release's current tag.
    func makeRequest(body: String?, currentTagName: String) -> ReleaseUpdateRequest {
        ReleaseUpdateRequest(
            tagName: newTag.flatMap { $0.isEmpty ? nil : $0 } ?? currentTagName,
            targetCommitish: target.flatMap { $0.isEmpty ? nil : $0 },
            name: title,
            body: body,
            draft: draft?.value,
            prerelease: prerelease?.value,
            makeLatest: latest.map { $0.value ? "true" : "false" },
            discussionCategoryName: discussionCategory)
    }

    /// cobra's `NFlag() == 0` check — any flag counts, `-R` included.
    private func requireFlags() throws {
        let anySet = repo != nil || draft != nil || prerelease != nil || latest != nil
            || notes != nil || title != nil || discussionCategory != nil || target != nil
            || newTag != nil || notesFile != nil || verifyTag != nil
        guard !anySet else { return }
        Shell.current.stderr.write(Data("use flags to specify properties to edit\n".utf8))
        throw ExitCode(1)
    }

    /// `cmdutil.ReadFile`: `-` drains stdin, anything else is a path
    /// read through the shell's sandbox gate.
    private static func readNotesFile(_ path: String) async throws -> String {
        if path == "-" {
            return String(decoding: await Shell.current.stdin.readAllData(), as: UTF8.self)
        }
        let url = Shell.resolve(path)
        try await Shell.authorize(url)
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}
