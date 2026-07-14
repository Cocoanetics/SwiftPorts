import ArgumentParser

struct Fetch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Download objects and refs from a remote."
    )

    @Option(name: [.customShort("r"), .long],
            help: "Remote name to fetch from.")
    var remote: String = "origin"

    @Argument(help: "Refspec to fetch (e.g. `main` or `+refs/heads/*:refs/remotes/origin/*`).")
    var refspec: String

    @Option(name: .customLong("depth"),
            help: "Limit fetching to the last N commits per tip.")
    var depth: Int?

    @Flag(name: .customLong("unshallow"),
          help: "Convert a shallow repository to a complete one.")
    var unshallow: Bool = false

    @Flag(name: [.customShort("p"), .long],
          help: "Prune remote-tracking branches no longer on the remote.")
    var prune: Bool = false

    func validate() throws {
        if let depth, depth <= 0 {
            throw ValidationError("--depth must be a positive integer")
        }
        if depth != nil && unshallow {
            throw ValidationError("--depth and --unshallow cannot be used together")
        }
    }

    func run() async throws {
        if unshallow {
            try await CommandContext.gitClient().unshallow(remote: remote, refspec: refspec)
        } else {
            try await CommandContext.gitClient().fetch(
                remote: remote, refspec: refspec, depth: depth, prune: prune)
        }
        // Progress and per-ref summaries are written by GitClient's
        // libgit2 callbacks through the active shell stderr.
    }
}
