import ArgumentParser
import Foundation
import GitLab
import ShellKit

/// `glab release create` — upstream's create-or-update command
/// (`internal/commands/release/create/create.go`). An existing release
/// for the tag is updated in place with one PUT; there is no separate
/// `release update` command upstream.
struct ReleaseCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new GitLab release, or update an existing one.",
        discussion: """
            An existing release is updated with the new information you provide.

            If the Git tag you specify doesn't exist, the command creates a release \
            from the latest state of the default branch, and tags it with the tag \
            name you specify. To override this behavior, use --ref.
            """
    )

    // String options take the next word verbatim (`-N '- Fixed a bug'`)
    // and accept a joined shorthand value (`-Nfixes`), as pflag does.
    @Option(name: [.customShort("R", allowingJoined: true), .long], parsing: .unconditional,
            help: "Repository as OWNER/REPO or GROUP/NAMESPACE/REPO.")
    var repo: RepositoryReference?

    @Option(name: [.customShort("n", allowingJoined: true), .customLong("name")],
            parsing: .unconditional,
            help: "The release name or title.")
    var name: String?

    @Option(name: [.customShort("r", allowingJoined: true), .customLong("ref")],
            parsing: .unconditional,
            help: """
                If the specified tag doesn't exist, create a release from the ref and tag it \
                with the specified tag name. Accepts a commit SHA, tag name, or branch name.
                """)
    var ref: String?

    @Option(name: [.customShort("N", allowingJoined: true), .customLong("notes")],
            parsing: .unconditional,
            help: "The release notes or description. Accepts Markdown.")
    var notes: String?

    @Option(name: [.customShort("F", allowingJoined: true), .customLong("notes-file")],
            parsing: .unconditional,
            help: """
                Read release notes 'file'. To read from stdin, use '-'. \
                If both --notes and --notes-file are set, --notes takes precedence.
                """)
    var notesFile: String?

    /// A pflag bool upstream: bare `--no-update` (rewritten to
    /// `--no-update=true` by ``GlabCommand/preprocess(_:)``) or an
    /// explicit `--no-update=false`.
    @Option(name: .customLong("no-update"), help: "Prevent updating the existing release.")
    var noUpdateValue: ReleaseCreateBool?

    var noUpdate: Bool { noUpdateValue?.value ?? false }

    @Argument(help: "Tag name (e.g. `v1.0.0`).")
    var tagName: String

    struct CreateBody: Encodable {
        let tagName: String
        let name: String
        let description: String?
        let ref: String?
    }

    func run() async throws {
        let target = try await CommandContext.resolveRepo(flag: repo)
        let client = try await CommandContext.apiClient(host: target.host)
        try await run(target: target, client: client)
    }

    func run(target: RepositoryReference, client: APIClient) async throws {
        let resolvedNotes = try await resolveNotes()
        let noteProvided = notes != nil || notesFile != nil || !resolvedNotes.isEmpty
        let project = "projects/\(target.encodedPath)"
        let tagPath = Self.encodeSegment(tagName)

        var ref = self.ref ?? ""
        if ref.isEmpty {
            Shell.print("• Validating tag \(tagName)")
            do {
                let _: Tag = try await client.get("\(project)/repository/tags/\(tagPath)")
            } catch APIError.notFound {
                Shell.print("• Tag does not exist.")
                Shell.print("• No ref provided. Creating the tag from the latest state of the default branch.")
                if let resolved = try? await client.get(project, as: Project.self) {
                    let branch = resolved.defaultBranch ?? ""
                    Shell.print("• using default branch \"\(branch)\" as ref")
                    ref = branch
                } else if let branch = Shell.current.environment.variables["CI_DEFAULT_BRANCH"] {
                    // A CI job token can't read the Projects API.
                    Shell.print("• using default branch \"\(branch)\" as ref from CI_DEFAULT_BRANCH")
                    ref = branch
                }
            }
        }

        let start = Date()
        Shell.print("• Creating or updating release repo=\(target.fullPath) tag=\(tagName)")

        let release: Release
        do {
            release = try await createOrUpdate(
                client: client, project: project, tagPath: tagPath,
                notes: resolvedNotes, noteProvided: noteProvided, ref: ref)
        } catch {
            throw Self.releaseFailed(error)
        }
        let elapsed = String(format: "%0.2f", Date().timeIntervalSince(start))
        Shell.print("✓ Release succeeded after \(elapsed) seconds.")
    }

    /// Lookup, then one PUT (existing) or one POST (absent). Every
    /// failure here goes through upstream's `releaseFailedErr`.
    private func createOrUpdate(
        client: APIClient, project: String, tagPath: String,
        notes resolvedNotes: String, noteProvided: Bool, ref: String
    ) async throws -> Release {
        let existing: Release?
        do {
            existing = try await client.get("\(project)/releases/\(tagPath)")
        } catch APIError.notFound {
            existing = nil
        } catch APIError.http(let status, _, _) where status == 403 {
            existing = nil
        }

        let release: Release
        if let existing {
            if noUpdate {
                throw ReleaseCreateError.alreadyExists(tag: tagName)
            }
            let request = updateRequest(
                existing: existing, notes: resolvedNotes, noteProvided: noteProvided)
            release = try await client.send(
                method: .put, path: "\(project)/releases/\(tagPath)", body: request)
            Shell.print("✓ Release updated\turl=\(release._links?.selfLink?.absoluteString ?? "")")
        } else {
            let body = createBody(notes: resolvedNotes, ref: ref)
            release = try await client.send(
                method: .post, path: "\(project)/releases", body: body)
            Shell.print("✓ Release created:\turl=\(release._links?.selfLink?.absoluteString ?? "")")
        }
        return release
    }

    /// Upstream `releaseFailedErr`. Its "release failed after N seconds."
    /// goes into `ExitError.Details`, which glab's error handler never
    /// prints (`ExitError.Error()` is the wrapped error alone), so the
    /// only visible change is the semantic-versioning hint on a 422.
    static func releaseFailed(_ error: Error) -> Error {
        if case APIError.http(let status, let message, _) = error, status == 422,
           message.lowercased().contains("semver must follow semantic version") {
            return ReleaseCreateError.semverTag(underlying: error)
        }
        return error
    }

    /// Upstream's update branch: resend the current name / description
    /// unless overridden; an empty effective name falls back to the tag.
    /// Release date, milestones and ref are never added.
    func updateRequest(existing: Release, notes: String, noteProvided: Bool) -> ReleaseUpdateRequest {
        var name = existing.name ?? ""
        if let provided = self.name { name = provided }
        if name.isEmpty { name = tagName }
        return ReleaseUpdateRequest(
            name: name,
            description: noteProvided ? notes : (existing.description ?? ""))
    }

    /// Upstream's create branch: the name falls back to the tag, and an
    /// empty description or ref is omitted.
    func createBody(notes: String, ref: String) -> CreateBody {
        CreateBody(
            tagName: tagName,
            name: self.name.flatMap { $0.isEmpty ? nil : $0 } ?? tagName,
            description: notes.isEmpty ? nil : notes,
            ref: ref.isEmpty ? nil : ref)
    }

    /// Upstream `resolveNotes`: `--notes` (even empty) wins; then a
    /// non-empty `--notes-file` (`-` drains stdin). A file passed
    /// alongside `--notes` is never opened.
    private func resolveNotes() async throws -> String {
        if let notes {
            if notesFile != nil {
                Shell.current.stderr.write(Data("""
                    ! --notes and --notes-file were both given: using --notes and ignoring --notes-file. \
                    Passing both will be an error in a future major release.

                    """.utf8))
            }
            return notes
        }
        guard let notesFile, !notesFile.isEmpty else { return "" }
        if notesFile == "-" {
            return String(decoding: await Shell.current.stdin.readAllData(), as: UTF8.self)
        }
        let url = Shell.resolve(notesFile)
        try await Shell.authorize(url)
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// One URL path segment: `/`, `%`, `?` and `#` in a tag are escaped
    /// so the tag can't split or truncate the route.
    static func encodeSegment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
