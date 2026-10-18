import ArgumentParser

struct Fetch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Download objects and refs from a remote.",
        discussion: """
            `git fetch [<repository> [<refspec>…]]`, as in git: the repository
            is a remote's name, a URL or a path. Without one it fetches from
            the current branch's remote, else the only remote configured,
            else `origin` if that is configured (else there is nothing to
            fetch). The refspecs are fetched together, so a negative
            `^<ref>` excludes what the others match; without any, it fetches
            what `remote.<name>.fetch` says, and with nothing configured
            (and for a URL or path) the remote's `HEAD`, into `FETCH_HEAD`.
            `--remote <name>` names the remote instead, leaving every
            argument a refspec.
            """
    )

    @Option(name: [.customShort("r"), .long],
            help: "Remote to fetch from; every argument is then a refspec.")
    var remote: String?

    @Argument(help: "The remote, then the refspecs to fetch (e.g. `origin main`).")
    var arguments: [String] = []

    @Option(name: .customLong("depth"),
            help: "Limit fetching to the last N commits per tip.")
    var depth: Int?

    @Flag(name: .customLong("unshallow"),
          help: "Convert a shallow repository to a complete one.")
    var unshallow: Bool = false

    @Flag(name: [.customShort("p"), .long],
          inversion: .prefixedNo,
          help: "Prune remote-tracking branches no longer on the remote.")
    var prune: Bool?

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress progress output.")
    var quiet: Bool = false

    func validate() throws {
        if let depth, depth <= 0 {
            throw ValidationError("--depth must be a positive integer")
        }
        if depth != nil && unshallow {
            throw ValidationError("--depth and --unshallow cannot be used together")
        }
    }

    func run() async throws {
        let client = CommandContext.gitClient(quiet: quiet)
        let (remoteName, refspecs) = RemoteArguments.split(arguments, remote: remote)
        let name: String
        if let remoteName {
            name = remoteName
        } else {
            var branchRemote: String?
            if let branch = try await client.currentBranch() {
                branchRemote = try await client.configGet("branch.\(branch).remote")
            }
            let fallback = try await RemoteArguments.defaultRemote(
                client: client, branchRemote: branchRemote)
            // Without a configured remote to fall back on, git has
            // nothing to fetch, and says nothing.
            guard fallback.isUsable else { return }
            name = fallback.name
        }
        // One fetch for every refspec, as git applies them; with none,
        // the remote's configured refspecs (or its HEAD).
        if unshallow {
            try await client.unshallow(remote: name, refspecs: refspecs, prune: prune)
        } else {
            try await client.fetch(remote: name, refspecs: refspecs, depth: depth, prune: prune)
        }
        // Progress and per-ref summaries are written by GitClient's
        // libgit2 callbacks through the active shell stderr.
    }
}
