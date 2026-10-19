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
        } catch let error as RemoteRepositoryError {
            throw CLIError(error)
        }
    }

    private func pull() async throws {
        let client = CommandContext.gitClient(quiet: quiet)
        // Unmerged entries stop a pull first, a merge waiting to be
        // concluded next, both before it fetches.
        try await Merge.refuseUnmergedEntries(client: client, verb: "Pulling")
        // A merge waiting to be concluded stops a pull before it fetches.
        if let gitDir = try await client.gitDir(),
           FileManager.default.fileExists(atPath: gitDir + "/MERGE_HEAD") {
            var advise = try await client.configBool("advice.resolveConflict") ?? true
            if advise, let environment = Shell.current.environment["GIT_ADVICE"] {
                advise = try SwiftGit.GitClient.parseGitBoolEnvironment(environment, name: "GIT_ADVICE")
            }
            throw CLIError.stderr(["error: You have not concluded your merge (MERGE_HEAD exists)."]
                                  + (advise ? ["hint: Please, commit your changes before merging."] : [])
                                  + ["fatal: Exiting because of unfinished merge."], exitCode: 128)
        }
        // An unborn branch is a branch too.
        var branch = try await client.currentBranch()
        if branch == nil { branch = try await client.symbolicHeadBranch() }

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

        // Before fetching, where the branch forked from its upstream's
        // remote-tracking branch (`merge-base --fork-point`), which a
        // rebase replays from, as git's pull does: commits the upstream
        // dropped since stay dropped.
        var forkPoint: String?
        // Only for the upstream: no refspec, and no other remote named.
        if rebasing != .no, arguments.count <= 1, let branch,
           let remote = try await client.configGet("branch.\(branch).remote"),
           let merge = try await client.configGet("branch.\(branch).merge"),
           arguments.first == nil || arguments.first == remote {
            // The upstream's ref here: the branch itself from `.`, else
            // where the remote's fetch refspecs put it.
            let tracking: String?
            if remote == "." {
                tracking = merge
            } else {
                let key = "remote.\(remote).fetch"
                let mappings = try await client.configList()
                    .filter { $0.name.dropFirst(7).dropLast(6) == remote && $0.name.lowercased() == key.lowercased() }
                    .map(\.value)
                tracking = Self.destination(of: merge, under: mappings)
            }
            if let tracking {
                forkPoint = try await Self.forkPoint(of: tracking, client: client)
            }
        }

        // Fetch, as `git fetch [<repository> [<refspec>…]]` would.
        let repository = arguments.first
        var refspecs = try Self.normalizingTagRefspecs(Array(arguments.dropFirst()))
        var branchRemote: String?
        if let branch { branchRemote = try await client.configGet("branch.\(branch).remote") }
        let remotes = try await client.remoteList()
        // The remote to fetch from, `nil` when there's none.
        var fetchFrom = repository
        // An empty repository is no remote: git's fetch does nothing,
        // and there is nothing to merge.
        if repository == "" { fetchFrom = nil }
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
            // An empty `remote.<name>.fetch` maps nothing.
            var mapped = false
            var blank = false
            // Without an upstream, git merges the first refspec if it
            // isn't a pattern.
            var firstIsExact = false
            var firstIsBlank = false
            var mappings: [String] = []
            if remotes.contains(fetchFrom) {
                // Section and key in any case, the remote's name as is.
                let values = try await client.configList().filter { entry in
                    let name = entry.name
                    guard name.count == "remote..fetch".count + fetchFrom.count,
                          name.lowercased().hasPrefix("remote."), name.lowercased().hasSuffix(".fetch")
                    else { return false }
                    return name.dropFirst(7).dropLast(6) == fetchFrom
                }.map(\.value)
                mappings = values.filter { !$0.isEmpty }
                mapped = !mappings.isEmpty
                blank = !mapped && !values.isEmpty
                // An empty refspec, first, is an exact one: the remote's HEAD.
                firstIsExact = values.first.map { !$0.contains("*") } ?? false
                firstIsBlank = mapped && values.first == ""
            }
            let upstreamHere = upstreamMerge != nil && fetchFrom == branchRemote
            if refspecs.isEmpty, !mapped, upstreamHere, let upstreamMerge {
                refspecs = [upstreamMerge]
            } else if refspecs.isEmpty, blank {
                // GitKit reads an empty refspec as one; git fetches HEAD.
                refspecs = ["HEAD"]
            }
            wantsMerge = !refspecs.isEmpty || !mapped || upstreamHere
                || (upstreamMerge == nil && firstIsExact)
            try await client.fetch(remote: fetchFrom, refspecs: refspecs, depth: nil)
            // An upstream the mappings don't fetch, git fetches as well
            // (add_merge_config), into FETCH_HEAD.
            if refspecs.isEmpty, mapped, upstreamHere, let upstreamMerge,
               !Self.refspecs(mappings, fetch: upstreamMerge) {
                try await client.fetch(remote: fetchFrom, refspecs: [upstreamMerge], depth: nil)
            } else if refspecs.isEmpty, upstreamMerge == nil, firstIsBlank {
                // GitKit skips the empty refspec; git merges the HEAD it fetches.
                try await client.fetch(remote: fetchFrom, refspecs: ["HEAD"], depth: nil)
            }
        }
        let heads = wantsMerge ? try await client.fetchHeadEntries().filter(\.isMerge) : []
        guard let head = heads.first else {
            throw noMergeCandidates(
                branch: branch, branchRemote: branchRemote, upstreamMerge: upstreamMerge,
                remotes: remotes, rebasing: rebasing != .no)
        }
        let current = try? await client.resolveOID("HEAD")
        if heads.count > 1 {
            if current == nil {
                throw CLIError.stderr("fatal: Cannot merge multiple branches into empty head.", exitCode: 128)
            }
            if rebasing != .no {
                throw CLIError.stderr("fatal: Cannot rebase onto multiple branches.", exitCode: 128)
            }
            if fastForward == .only {
                throw CLIError.stderr("fatal: Cannot fast-forward to multiple branches.", exitCode: 128)
            }
        }

        // Whether HEAD can fast-forward to what was fetched, or already
        // has it; an unborn branch takes it as it is. Several heads never
        // fast-forward, as git sees it, and have diverged unless HEAD has
        // them all.
        var canFastForward = true
        var divergent = false
        if let current {
            canFastForward = heads.count == 1
            var upToDate = true
            for each in heads {
                // An annotated tag by the commit it names.
                let commit = (try? await client.resolveOID(each.oid + "^{commit}")) ?? each.oid
                let base = try? await client.mergeBase(current, commit)
                if heads.count == 1 { canFastForward = base == current }
                if base != commit { upToDate = false }
            }
            divergent = !canFastForward && !upToDate
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
               try await client.log(LogQuery(starts: ["HEAD"], excludes: [forkPoint ?? head.oid]))
                .contains(where: \.isMerge) {
                throw CLIError.stderr(
                    "fatal: rebasing merge commits (pull.rebase=merges) is not supported", exitCode: 128)
            }
            let outcome = try await client.rebase(
                upstream: forkPoint ?? head.oid, onto: head.oid, author: nil) { current, total in
                if !quiet { Rebase.emitProgress(current: current, total: total) }
            }
            if !quiet {
                try Rebase.printOutcome(outcome)
            } else if case .conflict = outcome {
                try Rebase.printOutcome(outcome)
            }
            return
        }

        // An annotated tag fetched outside its natural place
        // (`refs/tags/<name>`) is merged with --no-ff unless told
        // otherwise, as git merges one.
        // Several heads are checked once reduced, below.
        if rebasing == .no, fastForward == nil, heads.count == 1,
           try await Self.isTagOutsideItsPlace(head, client: client) {
            fastForward = .never
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
            // The repository as typed, or as `branch.<name>.remote` has it.
            mergeMessage = try await client.pullMergeMessage(
                for: Self.messageHeads(heads, current: current, client: client), repository: fetchFrom)
        }
        if heads.count > 1 {
            // git's merge of `FETCH_HEAD`: the heads named by their
            // object names, the message from all that were fetched.
            let reduced = try await client.mergeHeads(reducing: heads.map(\.oid))
            // Any annotated tag outside its natural place merges --no-ff.
            var octopusMode = mode
            if rebasing == .no, fastForward == nil {
                for head in heads where reduced.heads.contains(head.oid) {
                    if try await Self.isTagOutsideItsPlace(head, client: client) { octopusMode = .never }
                }
            }
            try await Merge.merge(heads: reduced, mode: octopusMode, message: mergeMessage ?? "",
                                  client: client, quiet: quiet)
            return
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

    /// The fetched heads git's merge message names (fmt-merge-msg's
    /// `find_merge_parents`): those whose commit survives reducing HEAD
    /// and all of them. One HEAD already has, or another head has, drops
    /// out; one that is HEAD, or the same commit as another, stays.
    static func messageHeads(
        _ heads: [SwiftGit.GitClient.FetchHeadEntry], current: String?, client: SwiftGit.GitClient
    ) async throws -> [SwiftGit.GitClient.FetchHeadEntry] {
        guard heads.count > 1 else { return heads }
        func contains(_ commit: String, _ ancestor: String) async -> Bool {
            guard commit != ancestor else { return false }
            return (try? await client.mergeBase(commit, ancestor)) == ancestor
        }
        // Compared as commits: an annotated tag by the commit it names.
        var commits: [String] = []
        for head in heads { commits.append((try? await client.resolveOID(head.oid + "^{commit}")) ?? head.oid) }
        var kept: [SwiftGit.GitClient.FetchHeadEntry] = []
        for (head, commit) in zip(heads, commits) {
            if let current, await contains(current, commit) { continue }
            var reachable = false
            for other in commits where !reachable { reachable = await contains(other, commit) }
            if !reachable { kept.append(head) }
        }
        return kept
    }

    /// Where fetch refspecs `refspecs` store remote ref `ref`: the
    /// destination of the last one that maps it (as git's remote-tracking
    /// lookup picks it), `nil` when none does or a negative one excludes it.
    static func destination(of ref: String, under refspecs: [String]) -> String? {
        let full = ref.hasPrefix("refs/") ? ref : "refs/heads/" + ref
        var found: String?
        for refspec in refspecs {
            if refspec.hasPrefix("^") {
                if Self.refspecs([String(refspec.dropFirst())], fetch: full) { return nil }
                continue
            }
            let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
            let sides: [Substring] = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard sides.count == 2, !sides[1].isEmpty else { continue }
            let (source, target) = (String(sides[0]), String(sides[1]))
            if let star = source.firstIndex(of: "*"), let targetStar = target.firstIndex(of: "*") {
                let prefix = source[..<star], suffix = source[source.index(after: star)...]
                guard full.count >= prefix.count + suffix.count,
                      full.hasPrefix(prefix), full.hasSuffix(suffix) else { continue }
                let middle = full.dropFirst(prefix.count).dropLast(suffix.count)
                found = String(target[..<targetStar]) + middle + target[target.index(after: targetStar)...]
            } else if ["", "refs/", "refs/heads/"].contains(where: { $0 + source == full }) {
                found = target
            }
        }
        return found
    }

    /// `git merge-base --fork-point <ref> HEAD`: the newest of `ref`'s
    /// values, its reflog's included, that HEAD descends from; `nil`
    /// when there's none.
    static func forkPoint(of ref: String, client: SwiftGit.GitClient) async throws -> String? {
        guard let head = try? await client.resolveOID("HEAD") else { return nil }
        var candidates: [String] = []
        if let tip = try? await client.resolveOID(ref) { candidates.append(tip) }
        candidates += ((try? await client.reflog(refName: ref)) ?? []).map(\.newSHA)
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if (try? await client.mergeBase(candidate, head)) == candidate { return candidate }
        }
        return nil
    }

    /// git fetch's `tag <name>`, which is one refspec,
    /// `refs/tags/<name>:refs/tags/<name>`; a `tag` without a name is
    /// refused as git fetch refuses it.
    static func normalizingTagRefspecs(_ arguments: [String]) throws -> [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == "tag" {
                guard index + 1 < arguments.endIndex else {
                    throw CLIError.stderr("fatal: you need to specify a tag name", exitCode: 1)
                }
                let name = arguments[index + 1]
                result.append("refs/tags/\(name):refs/tags/\(name)")
                index += 2
            } else {
                result.append(arguments[index])
                index += 1
            }
        }
        return result
    }

    /// Whether `head` is an annotated tag that `refs/tags/<name>` doesn't
    /// hold, as git's merge checks it (`merge_name`, natural place).
    static func isTagOutsideItsPlace(_ head: SwiftGit.GitClient.FetchHeadEntry,
                                     client: SwiftGit.GitClient) async throws -> Bool {
        // The name runs to the quote before ` of ` (a ref name holds no
        // space, but may hold a quote: `tag 'v'1' of …`), or to the last.
        let description = head.description
        guard description.hasPrefix("tag '"),
              let end = description.range(of: "' of ")?.lowerBound ?? description.lastIndex(of: "'"),
              end > description.index(description.startIndex, offsetBy: 4),
              (try? await client.objectMetadata(of: head.oid))?.kind == .tag
        else { return false }
        let name = description[description.index(description.startIndex, offsetBy: 5)..<end]
        return (try? await client.resolveOID("refs/tags/\(name)")) != head.oid
    }

    /// Whether fetch refspecs `refspecs` fetch remote ref `ref`
    /// (`refs/heads/x`, or as short as git takes it): one's source names
    /// or matches it, and no negative one excludes it.
    static func refspecs(_ refspecs: [String], fetch ref: String) -> Bool {
        let full = ref.hasPrefix("refs/") ? ref : "refs/heads/" + ref
        func matches(_ source: Substring) -> Bool {
            let source = String(source)
            if let star = source.firstIndex(of: "*") {
                let prefix = source[..<star], suffix = source[source.index(after: star)...]
                return full.count >= prefix.count + suffix.count
                    && full.hasPrefix(prefix) && full.hasSuffix(suffix)
            }
            return ["", "refs/", "refs/heads/", "refs/tags/"].contains { $0 + source == full }
        }
        var fetched = false
        for refspec in refspecs {
            if refspec.hasPrefix("^") {
                if matches(refspec.dropFirst()) { return false }
                continue
            }
            let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
            if matches(body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]) {
                fetched = true
            }
        }
        return fetched
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
        // A line's very first byte, as git looks at it.
        let starts = Set(message.utf8.split(separator: UInt8(ascii: "\n")).compactMap(\.first))
        return "#;@!$%^&|:".utf8.first { !starts.contains($0) }
            .map { String(UnicodeScalar($0)) } ?? "#"
    }

    /// Each physical line of `lines` as a comment, as git's
    /// `strbuf_add_commented_lines` writes it: `comment` then a space,
    /// with no space before a tab or on an empty line.
    static func commented(_ lines: [String], with comment: String) -> String {
        lines.flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false) }
            .map { line in
                line.isEmpty || line.hasPrefix("\t") ? "\(comment)\(line)\n" : "\(comment) \(line)\n"
            }
            .joined()
    }

    /// `MERGE_MSG` for a merge stopped by conflicts, as git leaves it for
    /// the commit that concludes the merge.
    static func writeMergeMessage(_ message: String, conflicts: [String], client: SwiftGit.GitClient) async throws {
        guard let gitDir = try await client.gitDir() else { return }
        let comment = try await commentString(for: message, client: client)
        let text = message + "\n\n" + commented(["Conflicts:"] + conflicts.map { "\t\($0)" }, with: comment)
        try Data(text.utf8).write(to: URL(fileURLWithPath: gitDir).appendingPathComponent("MERGE_MSG"))
    }
}

private extension String {
    /// `hint:` with nothing after it is written without the space.
    var trimmingTrailingSpace: String { hasSuffix(" ") ? String(dropLast()) : self }
}
