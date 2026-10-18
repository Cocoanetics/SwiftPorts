import ArgumentParser
import ShellKit
import SwiftGit

struct Push: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Update remote refs along with associated objects.",
        discussion: """
            `git push [<repository> [<refspec>…]]`, as in git: the repository
            is a remote's name, a URL or a path. Without a refspec it pushes
            the current branch as `push.default` says (`simple` unless
            configured). `--remote <name>` names the remote instead, leaving
            every argument a refspec.
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
        var upstream = setUpstream
        if refspecs.isEmpty {
            let plan = try await CurrentBranchPush.plan(client: client, remote: remoteName)
            remoteName = plan.remote
            refspecs = [plan.refspec]
            upstream = upstream || plan.setUpstream
        }
        let target = remoteName ?? "origin"
        for refspec in refspecs {
            try await client.push(remote: target, refspec: refspec, setUpstream: upstream)
        }
        // Like git, confirm each upstream recorded for a configured remote.
        guard upstream, !quiet, (try? await client.remoteExists(named: target)) == true else { return }
        for refspec in refspecs {
            guard let (local, remoteBranch) = Self.branchNames(in: refspec) else { continue }
            Shell.print("branch '\(local)' set up to track '\(target)/\(remoteBranch)'.")
        }
    }

    /// The local and remote branch a refspec like `main`, `+a:b` or
    /// `refs/heads/a:refs/heads/b` pushes, or `nil` for anything else.
    static func branchNames(in refspec: String) -> (local: String, remote: String)? {
        let body = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
        let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        func branch(_ ref: Substring) -> String? {
            if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
            if ref.isEmpty || ref == "HEAD" || ref.hasPrefix("refs/") { return nil }
            return String(ref)
        }
        guard let local = parts.first.flatMap(branch),
              let remote = branch(parts.count > 1 ? parts[1] : parts[0])
        else { return nil }
        return (local, remote)
    }
}

/// What `git push [<repository>]` pushes when no refspec is given:
/// the current branch, as `push.default` (`simple` unless configured)
/// and `push.autoSetupRemote` say, with git's refusals.
enum CurrentBranchPush {
    static func plan(
        client: SwiftGit.GitClient, remote explicit: String?
    ) async throws -> (remote: String, refspec: String, setUpstream: Bool) {
        guard let branch = try await client.currentBranch() else {
            throw CLIError.stderr([
                "fatal: You are not currently on a branch.",
                "To push the history leading to the current (detached HEAD)",
                "state now, use",
                "",
                "    git push \(explicit ?? "origin") HEAD:<name-of-remote-branch>",
                ""
            ], exitCode: 128)
        }
        let upstreamRemote = try await client.configGet("branch.\(branch).remote")
        let upstreamBranch = try await client.configGet("branch.\(branch).merge")
            .map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 }
        let pullRemote = upstreamRemote ?? "origin"
        var target = explicit
        if target == nil { target = try await client.configGet("remote.pushDefault") }
        let remote = target ?? pullRemote
        let mode = try await client.configGet("push.default") ?? "simple"

        if mode == "nothing" {
            throw CLIError.stderr(
                "fatal: You didn't specify any refspecs to push, and push.default is \"nothing\".",
                exitCode: 128)
        }
        // `current` — and `simple` pushing somewhere other than where the
        // branch pulls from, a triangular workflow — pushes the branch
        // under its own name.
        if mode == "current" || (mode == "simple" && remote != pullRemote) {
            return (remote, branch, false)
        }
        guard upstreamRemote != nil, let upstreamBranch else {
            let auto = try await client.configGet("push.autoSetupRemote")?.lowercased()
            if ["true", "yes", "on", "1"].contains(auto ?? "") {
                return (remote, branch, true)
            }
            throw CLIError.stderr([
                "fatal: The current branch \(branch) has no upstream branch.",
                "To push the current branch and set the remote as upstream, use",
                "",
                "    git push --set-upstream \(remote) \(branch)",
                "",
                "To have this happen automatically for branches without a tracking",
                "upstream, see 'push.autoSetupRemote' in 'git help config'.",
                ""
            ], exitCode: 128)
        }
        if mode == "simple", upstreamBranch != branch {
            throw CLIError.stderr([
                "fatal: The upstream branch of your current branch does not match",
                "the name of your current branch.  To push to the upstream branch",
                "on the remote, use",
                "",
                "    git push \(remote) HEAD:\(upstreamBranch)",
                "",
                "To push to the branch of the same name on the remote, use",
                "",
                "    git push \(remote) HEAD",
                "",
                "To choose either option permanently, see push.default in 'git help config'.",
                "",
                "To avoid automatically configuring an upstream branch when its name",
                "won't match the local branch, see option 'simple' of branch.autoSetupMerge",
                "in 'git help config'.",
                ""
            ], exitCode: 128)
        }
        return (remote, "\(branch):\(upstreamBranch)", false)
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
