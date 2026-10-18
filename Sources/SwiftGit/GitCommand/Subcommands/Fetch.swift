import ArgumentParser

struct Fetch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Download objects and refs from a remote.",
        discussion: """
            `git fetch [<repository> [<refspec>…]]`, as in git. Without a
            repository it fetches from the current branch's upstream remote
            (else `origin`); without a refspec, the remote's configured
            ones. `--remote <name>` names the remote instead, leaving every
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
        var (remoteName, refspecs) = RemoteArguments.split(arguments, remote: remote)
        let name: String
        if let remoteName {
            name = remoteName
        } else if let branch = try await client.currentBranch(),
                  let upstream = try await client.configGet("branch.\(branch).remote") {
            name = upstream
        } else {
            name = "origin"
        }
        if refspecs.isEmpty {
            refspecs = [try await client.configGet("remote.\(name).fetch")
                        ?? "+refs/heads/*:refs/remotes/\(name)/*"]
        }
        for refspec in refspecs {
            if unshallow {
                try await client.unshallow(remote: name, refspec: refspec, prune: prune)
            } else {
                try await client.fetch(remote: name, refspec: refspec, depth: depth, prune: prune)
            }
        }
        // Progress and per-ref summaries are written by GitClient's
        // libgit2 callbacks through the active shell stderr.
    }
}
