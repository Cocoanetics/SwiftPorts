import ArgumentParser

struct Push: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Update remote refs along with associated objects.",
        discussion: """
            `git push [<repository> [<refspec>…]]`, as in git. Without a
            refspec it pushes the current branch; without a repository, to
            that branch's upstream remote. `--remote <name>` names the
            remote instead, leaving every argument a refspec.
            """
    )

    @Flag(name: [.customShort("u"), .customLong("set-upstream")],
          help: "Set the upstream tracking reference for the pushed branch.")
    var setUpstream: Bool = false

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress progress output.")
    var quiet: Bool = false

    @Option(name: [.customShort("r"), .long],
            help: "Remote to push to; every argument is then a refspec.")
    var remote: String?

    @Argument(help: "The remote, then the refspecs to push (e.g. `origin main`).")
    var arguments: [String] = []

    func run() async throws {
        let client = CommandContext.gitClient(quiet: quiet)
        var (remoteName, refspecs) = RemoteArguments.split(arguments, remote: remote)
        if refspecs.isEmpty {
            // Like `push.default=simple`: the current branch, to its
            // upstream remote unless one was named.
            guard let branch = try await client.currentBranch() else {
                throw CLIError.stderr("fatal: You are not currently on a branch.", exitCode: 128)
            }
            if remoteName == nil {
                remoteName = try await client.configGet("branch.\(branch).remote")
            }
            guard remoteName != nil else {
                throw CLIError.stderr([
                    "fatal: The current branch \(branch) has no upstream branch.",
                    "To push the current branch and set the remote as upstream, use",
                    "",
                    "    git push --set-upstream origin \(branch)",
                    ""
                ], exitCode: 128)
            }
            refspecs = [branch]
        }
        for refspec in refspecs {
            try await client.push(
                remote: remoteName ?? "origin", refspec: refspec, setUpstream: setUpstream)
        }
    }
}

/// `[<repository> [<refspec>…]]`, the argument shape `git push` and
/// `git fetch` share.
enum RemoteArguments {
    /// The remote and the refspecs. With `--remote` given, every
    /// argument is a refspec (the older SwiftPorts spelling); otherwise
    /// the first one names the remote.
    static func split(_ arguments: [String], remote: String?) -> (remote: String?, refspecs: [String]) {
        if let remote { return (remote, arguments) }
        guard let first = arguments.first else { return (nil, []) }
        return (first, Array(arguments.dropFirst()))
    }
}
