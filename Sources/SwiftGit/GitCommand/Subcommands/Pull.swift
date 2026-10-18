import ArgumentParser
import Foundation
import ShellKit
import SwiftGit

struct Pull: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Fetch from and integrate with another repository or branch.",
        discussion: """
            `git pull [<repository> [<refspec>…]]`, as in git: `fetch` with
            the same arguments, then a merge (or rebase) of what the fetch
            marked for merging in `FETCH_HEAD`. Without a repository it
            fetches from the current branch's remote, else the only remote,
            else `origin`; without a refspec it merges the branch's upstream
            (`branch.<name>.merge`), which needs the repository, if named,
            to be the branch's remote. Whether to rebase comes from
            `--rebase`/`--no-rebase`, else `branch.<name>.rebase`, else
            `pull.rebase` (`merges` only while there are no merges to
            replay; `interactive` only to fast-forward); how to merge from `--ff`/`--no-ff`/`--ff-only`, else
            `pull.ff`. With neither configured, branches that have diverged
            are refused, as git refuses them.
            """
    )

    @Flag(name: [.customShort("r"), .long], inversion: .prefixedNo,
          help: "Rebase the current branch onto the upstream instead of merging.")
    var rebase: Bool?

    @Flag(name: .customLong("ff"),
          help: "Fast-forward when possible, else merge.")
    var ff: Bool = false

    @Flag(name: .customLong("no-ff"),
          help: "Always create a merge commit (ignored with --rebase).")
    var noFF: Bool = false

    @Flag(name: .customLong("ff-only"),
          help: "Refuse to merge unless fast-forward is possible.")
    var ffOnly: Bool = false

    @Option(name: [.customShort("m"), .customLong("message")],
            help: "Merge commit message (3-way merges only).")
    var message: String?

    @Flag(name: [.customShort("q"), .customLong("quiet")],
          help: "Suppress progress and the merge summary; conflicts are still reported.")
    var quiet: Bool = false

    @Argument(help: "The remote, then the refspecs to fetch and merge (e.g. `origin main`).")
    var arguments: [String] = []

    func validate() throws {
        let count = [ff, noFF, ffOnly].filter { $0 }.count
        if count > 1 {
            throw ValidationError("only one of --ff / --no-ff / --ff-only may be set")
        }
    }

    /// git's `--ff`, `--no-ff` and `--ff-only` (and `pull.ff`).
    enum FastForward { case allow, never, only }

    /// git's rebase choice (`--rebase`, `pull.rebase`).
    enum RebaseChoice { case no, yes, merges, interactive }

    func run() async throws {
        do {
            try await pull()
        } catch let error as UnsupportedTransportError {
            throw CLIError(error)
        }
    }

    private func pull() async throws {
        let client = CommandContext.gitClient(quiet: quiet)
        let branch = try await client.currentBranch()

        // git reads `pull.ff` unless the command line says, and lets a
        // command-line `--rebase`/`--no-rebase` turn its `only` into `--ff`.
        var fastForward: FastForward? = ff ? .allow : noFF ? .never : ffOnly ? .only : nil
        if fastForward == nil {
            fastForward = try await Self.configuredFastForward(client: client)
            if rebase != nil, fastForward == .only { fastForward = .allow }
        }
        let configuredRebase = rebase == nil ? try await Self.configuredRebase(client: client, branch: branch) : nil
        var rebasing = rebase.map { $0 ? RebaseChoice.yes : .no } ?? configuredRebase ?? .no
        let rebaseUnspecified = rebase == nil && configuredRebase == nil

        // Fetch, as `git fetch [<repository> [<refspec>…]]` would.
        let repository = arguments.first
        var refspecs = Array(arguments.dropFirst())
        var branchRemote: String?
        if let branch { branchRemote = try await client.configGet("branch.\(branch).remote") }
        let remotes = try await client.remoteList()
        // The remote to fetch from, `nil` when there's none.
        var fetchFrom = repository
        if let repository, repository.isEmpty {
            throw CLIError.stderr("fatal: bad repository ''", exitCode: 128)
        }
        if repository == nil {
            let fallback = RemoteArguments.defaultRemote(branchRemote: branchRemote, remotes: remotes)
            if fallback.isUsable { fetchFrom = fallback.name }
        }

        // What git's fetch marks for merging (get_ref_map): the refspecs
        // given; else the branch's upstream when this is the branch's
        // remote — fetched by name if `remote.<name>.fetch` doesn't map
        // it (a branch with `branch.<name>.merge` but no
        // `branch.<name>.remote` has none); else, without
        // `remote.<name>.fetch` (a URL or path too), the remote's HEAD.
        var upstreamMerge: String?
        if let branch, branchRemote != nil {
            upstreamMerge = try await client.configGet("branch.\(branch).merge")
        }
        var wantsMerge = false
        if let fetchFrom {
            var mapped = false
            if remotes.contains(fetchFrom) {
                mapped = try await client.configGet("remote.\(fetchFrom).fetch") != nil
            }
            let upstreamHere = upstreamMerge != nil && fetchFrom == branchRemote
            if refspecs.isEmpty, !mapped, upstreamHere, let upstreamMerge {
                refspecs = [upstreamMerge]
            }
            wantsMerge = !refspecs.isEmpty || !mapped || upstreamHere
            try await client.fetch(remote: fetchFrom, refspecs: refspecs, depth: nil)
        }
        let heads = wantsMerge ? try await client.fetchHeadEntries().filter(\.isMerge) : []
        guard let head = heads.first else {
            throw noMergeCandidates(
                branch: branch, branchRemote: branchRemote, upstreamMerge: upstreamMerge,
                remotes: remotes, rebasing: rebasing != .no)
        }
        if heads.count > 1 {
            if rebasing != .no {
                throw CLIError.stderr("fatal: Cannot rebase onto multiple branches.", exitCode: 128)
            }
            throw CLIError.stderr(
                "fatal: merging more than one branch (an octopus merge) is not supported", exitCode: 128)
        }

        // Whether HEAD can fast-forward to what was fetched, or already
        // has it; an unborn branch takes it as it is.
        var canFastForward = true
        var divergent = false
        if let current = try? await client.resolveOID("HEAD") {
            let base = try? await client.mergeBase(current, head.oid)
            canFastForward = base == current
            divergent = !canFastForward && base != head.oid
        }

        // `--ff-only` outranks a rebase.
        if fastForward == .only {
            if divergent { throw try await Self.notPossibleToFastForward(client: client) }
            rebasing = .no
        }
        if fastForward == nil, rebaseUnspecified, divergent {
            throw CLIError.stderr(Self.reconcileHint.map { "hint: \($0)".trimmingTrailingSpace }
                                  + ["fatal: Need to specify how to reconcile divergent branches."],
                                  exitCode: 128)
        }

        if rebasing != .no, !canFastForward {
            // GitKit's rebase replays commits one by one: it can neither
            // recreate merges (`--rebase-merges`) nor ask what to do.
            if rebasing == .interactive {
                throw CLIError.stderr(
                    "fatal: an interactive rebase (pull.rebase=interactive) is not supported", exitCode: 128)
            }
            if rebasing == .merges,
               try await client.log(LogQuery(starts: ["HEAD"], excludes: [head.oid])).contains(where: \.isMerge) {
                throw CLIError.stderr(
                    "fatal: rebasing merge commits (pull.rebase=merges) is not supported", exitCode: 128)
            }
            let outcome = try await client.rebase(upstream: head.oid, author: nil) { current, total in
                if !quiet { Rebase.emitProgress(current: current, total: total) }
            }
            if !quiet {
                try Rebase.printOutcome(outcome)
            } else if case .conflict = outcome {
                try Rebase.printOutcome(outcome)
            }
            return
        }

        // A rebase that can fast-forward does, as git does it.
        let mode: FastForwardMode
        switch rebasing != .no ? .only : fastForward {
        case .never?: mode = .never
        case .only?: mode = .onlyFastForward
        default: mode = .auto
        }
        var mergeMessage = message
        if mergeMessage == nil {
            mergeMessage = try await client.pullMergeMessage(for: head, repository: repository)
        }
        let outcome: MergeOutcome
        do {
            outcome = try await client.merge(
                ref: head.oid, fastForward: mode, message: mergeMessage, author: nil)
        } catch let err as Libgit2Error
            where err.message.contains("Not possible to fast-forward") {
            throw try await Self.notPossibleToFastForward(client: client)
        }
        if case .conflicts(let paths) = outcome {
            try await Self.writeMergeMessage(mergeMessage ?? "", conflicts: paths, client: client)
        }

        if !quiet {
            try Merge.printOutcome(outcome)
        } else if case .conflicts = outcome {
            try Merge.printOutcome(outcome)
        }
    }

    /// `pull.ff`: a boolean (`true` is `--ff`, `false` `--no-ff`) or
    /// `only`; `nil` when unset.
    static func configuredFastForward(client: SwiftGit.GitClient) async throws -> FastForward? {
        guard let value = try await client.configGet("pull.ff") else { return nil }
        if value == "only" { return .only }
        guard let flag = try await gitBool(value, key: "pull.ff", client: client) else {
            throw CLIError.stderr("fatal: invalid value for 'pull.ff': '\(value)'", exitCode: 128)
        }
        return flag ? .allow : .never
    }

    /// `branch.<name>.rebase`, else `pull.rebase`: a boolean, `merges`
    /// or `interactive` (each also by its initial); `nil` when neither
    /// is set.
    static func configuredRebase(client: SwiftGit.GitClient, branch: String?) async throws -> RebaseChoice? {
        let keys = (branch.map { ["branch.\($0).rebase"] } ?? []) + ["pull.rebase"]
        for key in keys {
            guard let value = try await client.configGet(key) else { continue }
            if let flag = try await gitBool(value, key: key, client: client) { return flag ? .yes : .no }
            if ["merges", "m"].contains(value) { return .merges }
            if ["interactive", "i"].contains(value) { return .interactive }
            throw CLIError.stderr("fatal: invalid value for '\(key)': '\(value)'", exitCode: 128)
        }
        return nil
    }

    /// Config `value` of `key` as git reads a boolean
    /// (`git_parse_maybe_bool`), or `nil` when it is none. A key written
    /// without a value (`[pull] rebase`) is true, an empty one false.
    static func gitBool(_ value: String, key: String, client: SwiftGit.GitClient) async throws -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off": return false
        // `configGet` reads both as empty; `configBool` tells them apart.
        case "": return try await client.configBool(key)
        default: return Int(value).map { $0 != 0 }
        }
    }

    /// Why there's nothing to merge, in git's words (`die_no_merge_candidates`).
    private func noMergeCandidates(
        branch: String?, branchRemote: String?, upstreamMerge: String?, remotes: [String],
        rebasing: Bool
    ) -> CLIError {
        let which = rebasing
            ? "Please specify which branch you want to rebase against."
            : "Please specify which branch you want to merge with."
        let lines: [String]
        if arguments.count > 1 {
            lines = [
                rebasing
                    ? "There is no candidate for rebasing against among the refs that you just fetched."
                    : "There are no candidates for merging among the refs that you just fetched.",
                "Generally this means that you provided a wildcard refspec which had no",
                "matches on the remote end."
            ]
        } else if let repository = arguments.first, branch != nil, branchRemote != repository {
            lines = [
                "You asked to pull from the remote '\(repository)', but did not specify",
                "a branch. Because this is not the default configured remote",
                "for your current branch, you must specify a branch on the command line."
            ]
        } else if branch == nil {
            lines = ["You are not currently on a branch.", which, "See git-pull(1) for details.",
                     "", "    git pull <remote> <branch>", ""]
        } else if let merge = upstreamMerge {
            lines = ["Your configuration specifies to merge with the ref '\(merge)'",
                     "from the remote, but no such ref was fetched."]
        } else {
            let remote = remotes.count == 1 ? remotes[0] : "<remote>"
            lines = ["There is no tracking information for the current branch.", which,
                     "See git-pull(1) for details.", "", "    git pull <remote> <branch>", "",
                     "If you wish to set tracking information for this branch you can do so with:",
                     "", "    git branch --set-upstream-to=\(remote)/<branch> \(branch ?? "")", ""]
        }
        return CLIError.stderr(lines, exitCode: 1)
    }

    /// git's refusal to fast-forward branches that have diverged, with
    /// its hint unless `advice.diverging` or `GIT_ADVICE` turns it off.
    /// Like git, it says how to turn the hint off unless
    /// `advice.diverging` is configured.
    static func notPossibleToFastForward(client: SwiftGit.GitClient) async throws -> CLIError {
        var lines: [String] = []
        let configured = try await client.configBool("advice.diverging")
        var advise = configured ?? true
        if advise, let environment = Shell.current.environment["GIT_ADVICE"] {
            advise = try SwiftGit.GitClient.parseGitBoolEnvironment(environment, name: "GIT_ADVICE")
        }
        if advise {
            var hint = [
                "Diverging branches can't be fast-forwarded, you need to either:", "",
                "\tgit merge --no-ff", "", "or:", "", "\tgit rebase"
            ]
            if configured == nil {
                hint += ["", "Disable this message with \"git config set advice.diverging false\""]
            }
            lines = hint.map { "hint: \($0)".trimmingTrailingSpace }
        }
        return CLIError.stderr(lines + ["fatal: Not possible to fast-forward, aborting."], exitCode: 128)
    }

    /// git's advice on a pull that doesn't say how to reconcile
    /// branches that have diverged, which no switch turns off.
    static let reconcileHint = [
        "You have divergent branches and need to specify how to reconcile them.",
        "You can do so by running one of the following commands sometime before",
        "your next pull:",
        "",
        "  git config pull.rebase false  # merge",
        "  git config pull.rebase true   # rebase",
        "  git config pull.ff only       # fast-forward only",
        "",
        "You can replace \"git config\" with \"git config --global\" to set a default",
        "preference for all repositories. You can also pass --rebase, --no-rebase,",
        "or --ff-only on the command line to override the configured default per",
        "invocation."
    ]

    /// What starts a comment line in a commit message: the last of
    /// `core.commentChar` and `core.commentString` configured (git reads
    /// them as one setting), else `#`; with `auto`, the first of git's
    /// candidates no line of `message` starts with.
    static func commentString(for message: String, client: SwiftGit.GitClient) async throws -> String {
        let configured = try await client.configList()
            .last { ["core.commentchar", "core.commentstring"].contains($0.name.lowercased()) }?.value
        guard let configured, !configured.isEmpty else { return "#" }
        guard configured.lowercased() == "auto" else { return configured }
        let starts = Set(message.split(separator: "\n").compactMap { $0.drop { $0 == " " }.first })
        return "#;@!$%^&|:".first { !starts.contains($0) }.map(String.init) ?? "#"
    }

    /// `MERGE_MSG` for a merge stopped by conflicts, as git leaves it for
    /// the commit that concludes the merge.
    static func writeMergeMessage(_ message: String, conflicts: [String], client: SwiftGit.GitClient) async throws {
        guard let gitDir = try await client.gitDir() else { return }
        let comment = try await commentString(for: message, client: client)
        let text = message + "\n\n\(comment) Conflicts:\n" + conflicts.map { "\(comment)\t\($0)\n" }.joined()
        try Data(text.utf8).write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("MERGE_MSG"))
    }
}

private extension String {
    /// `hint:` with nothing after it is written without the space.
    var trimmingTrailingSpace: String { hasSuffix(" ") ? String(dropLast()) : self }
}
