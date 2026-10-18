import ArgumentParser
import ShellKit
import SwiftGit

struct Push: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Update remote refs along with associated objects.",
        discussion: """
            `git push [<repository> [<refspec>…]]`, as in git: the repository
            is a remote's name, a URL or a path, and the refspecs go out in
            one push, patterns, `:` (matching branches) and negative `^<ref>`
            included. Without a repository it pushes to the current branch's
            `branch.<name>.pushRemote`, else `remote.pushDefault`, else the
            branch's remote, else the only remote configured, else `origin`
            if that is configured. Without a refspec it pushes what
            `remote.<name>.push` says, else what `push.default` (`simple`
            unless configured) says. `--remote <name>` names the remote
            instead, leaving every argument a refspec.

            `-f`/`--force` forces every refspec pushed, the configured ones
            included. `--force-with-lease` forces an update only while the
            remote ref is where its remote-tracking ref says;
            `--force-with-lease=<ref>` does so for `<ref>` alone, and
            `--force-with-lease=<ref>:<expect>` while it is at `<expect>`
            (absent, if empty). An update whose lease no longer holds is
            refused as `stale info`; `--force` overrides the lease.
            """
    )

    @Flag(name: [.customShort("f"), .long], inversion: .prefixedNo,
          help: "Force updates, even ones that aren't fast-forwards.")
    var force: Bool = false

    @Option(name: .customLong("force-with-lease"),
            help: ArgumentHelp(
                "Force updates only while the remote refs are where expected.",
                valueName: "refname[:expect]"))
    var leaseOptions: [String] = []

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
        let settings = try await DefaultPush.Settings(client: client)
        let (remoteName, refspecs) = RemoteArguments.split(arguments, remote: remote)
        // An empty repository is never read as a path.
        if remoteName == "" {
            throw CLIError.stderr("fatal: bad repository ''", exitCode: 128)
        }
        let leases = try await Self.leases(from: leaseOptions, client: client)
        // git reads every remote's config before pushing anywhere, and
        // refuses a push refspec written without a value.
        if let bare = try await client.valuelessRemotePush() {
            throw CLIError.stderr([
                "error: missing value for '\(bare.key)'",
                "fatal: bad config variable '\(bare.key)' in file '\(bare.file)' at line \(bare.line)"
            ], exitCode: 128)
        }
        let plan = refspecs.isEmpty
            ? try await DefaultPush.plan(client: client, remote: remoteName, settings: settings)
            : DefaultPush.Plan(remote: remoteName ?? "origin", refspecs: refspecs, setUpstream: false)
        let upstream = setUpstream || plan.setUpstream
        var pushRefspecs = plan.refspecs
        if force {
            // `--force` forces the configured refspecs too, so they're
            // read here rather than left to the push.
            if pushRefspecs.isEmpty {
                pushRefspecs = try await client.configGetAll("remote.\(plan.remote).push")
            }
            pushRefspecs = pushRefspecs.map(Self.forced)
        }
        do {
            let pushed = try await client.push(
                remote: plan.remote, refspecs: pushRefspecs, setUpstream: upstream,
                leases: leases)
            reportUpstreams(of: pushed, remote: plan.remote, upstream: upstream)
        } catch let rejected as PushRejectedError {
            // The refs that went through still got their upstream.
            reportUpstreams(of: rejected.pushed, remote: plan.remote, upstream: upstream)
            throw PushRejectionAdvice.error(
                for: rejected, currentBranch: try? await client.currentBranch(), quiet: quiet,
                switches: settings.advice)
        } catch let error as UnsupportedTransportError {
            throw CLIError(error)
        } catch let refused as PushRefusedError {
            // Refused before anything was sent, in git's words.
            throw PushRejectionAdvice.error(for: refused, switches: settings.advice)
        }
    }

    /// The bare `--force-with-lease`, as ``GitCommand/preprocess(_:)``
    /// passes it on: a ref name can't hold a control character.
    static let leaseAll = "\u{1}all"
    /// `--no-force-with-lease`, likewise.
    static let leaseNone = "\u{1}none"
    /// `--force-with-lease=`, a lease on a ref named nothing, which
    /// ArgumentParser would otherwise read as no value at all.
    static let leaseEmpty = "\u{1}empty"

    /// What the `--force-with-lease` options, in the order given, ask
    /// for (git's `parse_push_cas_option`), or `nil` for no lease at all.
    /// An `<expect>` is resolved now, as git does, and fails as git's
    /// usage error when it names no object.
    static func leases(from options: [String], client: SwiftGit.GitClient) async throws -> PushLeases? {
        var leases = PushLeases()
        for option in options {
            switch option {
            case leaseAll:
                leases.trackingForRest = true
            case leaseNone:
                leases = PushLeases()
            case leaseEmpty:
                leases.leases.append(.init(ref: "", expectation: .tracking))
            default:
                guard let colon = option.firstIndex(of: ":") else {
                    leases.leases.append(.init(ref: option, expectation: .tracking))
                    continue
                }
                let ref = String(option[..<colon])
                let expect = String(option[option.index(after: colon)...])
                guard !expect.isEmpty else {
                    leases.leases.append(.init(ref: ref, expectation: .absent))
                    continue
                }
                // A full object ID is taken as given, here or not (git's
                // get_oid); all zeros expects the ref absent. Object IDs
                // are SHA-1 ones: the libgit2 GitKit builds has no SHA-256.
                if expect.count == 40, expect.allSatisfy(\.isHexDigit) {
                    leases.leases.append(.init(
                        ref: ref,
                        expectation: expect.allSatisfy { $0 == "0" } ? .absent : .object(expect.lowercased())))
                    continue
                }
                guard let oid = try? await client.resolveOID(expect) else {
                    throw CLIError.stderr(
                        "error: cannot parse expected object name '\(expect)'", exitCode: 129)
                }
                leases.leases.append(.init(ref: ref, expectation: .object(oid)))
            }
        }
        return leases.leases.isEmpty && !leases.trackingForRest ? nil : leases
    }

    /// `refspec` forced, as `--force` forces it: a negative refspec has
    /// nothing to force.
    static func forced(_ refspec: String) -> String {
        refspec.hasPrefix("+") || refspec.hasPrefix("^") ? refspec : "+\(refspec)"
    }

    /// Like git, confirm each upstream `-u` recorded, for a URL or path too.
    private func reportUpstreams(of pushed: [String], remote: String, upstream: Bool) {
        guard upstream, !quiet else { return }
        for refspec in pushed {
            guard let (local, remoteBranch) = Self.branchNames(in: refspec) else { continue }
            Shell.print("branch '\(local)' set up to track '\(remote)/\(remoteBranch)'.")
        }
    }

    /// The local and remote branch of a refspec as GitKit reports it
    /// pushed (`refs/heads/a:refs/heads/b`), or `nil` for anything else,
    /// such as a tag, or a revision (`HEAD^`, an object ID) pushed to a
    /// branch, which GitKit passes through as typed.
    static func branchNames(in refspec: String) -> (local: String, remote: String)? {
        let body = refspec.hasPrefix("+") ? refspec.dropFirst() : Substring(refspec)
        let sides = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let prefix = "refs/heads/"
        let source = sides[0]
        let destination = sides.count > 1 ? sides[1] : source
        guard source.hasPrefix(prefix), destination.hasPrefix(prefix) else { return nil }
        return (String(source.dropFirst(prefix.count)), String(destination.dropFirst(prefix.count)))
    }
}

/// What `git push [<repository>]` pushes without a refspec, decided the
/// way git decides it: the remote is the one named, else the current
/// branch's `branch.<name>.pushRemote`, else `remote.pushDefault`, else
/// the branch's own remote, else the only remote, else `origin`. The
/// refspecs are that remote's `remote.<name>.push`, else what
/// `push.default` (`simple` unless configured) and
/// `push.autoSetupRemote` make of the current branch, with git's
/// refusals.
enum DefaultPush {
    struct Plan {
        let remote: String
        /// What to push; empty for the remote's `remote.<name>.push`.
        let refspecs: [String]
        /// Whether `push.autoSetupRemote` asks for `-u`.
        let setUpstream: Bool
    }

    /// `push.default`, `push.autoSetupRemote` and `branch.autoSetupMerge`,
    /// which git reads — and refuses when malformed — before anything
    /// else, even for a push whose refspecs leave them unused.
    struct Settings {
        /// `push.default` as configured; `nil` when it isn't.
        let configuredMode: String?
        let autoSetupRemote: Bool
        /// Whether `branch.autoSetupMerge` is `simple`, which drops the
        /// advice about it.
        let autoSetupMergeIsSimple: Bool
        /// Which hints a refused push gets (`GIT_ADVICE`, `advice.push*`).
        let advice: PushRejectionAdvice.Switches
        var mode: String { configuredMode ?? "simple" }

        init(client: SwiftGit.GitClient) async throws {
            configuredMode = try await client.configGet("push.default")
            switch configuredMode ?? "simple" {
            case "nothing", "matching", "simple", "upstream", "tracking", "current":
                break
            case let mode:
                throw CLIError.stderr([
                    "error: malformed value for push.default: \(mode)",
                    "error: must be one of nothing, matching, simple, upstream or current",
                    "fatal: bad config variable 'push.default'"
                ], exitCode: 128)
            }
            do {
                autoSetupRemote = try await client.configBool("push.autoSetupRemote") ?? false
                // `always`, `inherit`, `simple`, or else a boolean.
                let autoSetupMerge = try await client.configGet("branch.autoSetupMerge")
                if let autoSetupMerge, !["always", "inherit", "simple"].contains(autoSetupMerge) {
                    _ = try await client.configBool("branch.autoSetupMerge")
                }
                autoSetupMergeIsSimple = autoSetupMerge == "simple"
                var advice = PushRejectionAdvice.Switches()
                for key in PushRejectionAdvice.Switches.keys {
                    if try await client.configBool("advice.\(key)") == false {
                        advice.off.insert(key.lowercased())
                    }
                }
                // `GIT_ADVICE` is a boolean, read once a hint is due.
                advice.environment = Shell.current.environment["GIT_ADVICE"]
                self.advice = advice
            } catch let error as Libgit2Error {
                throw CLIError.stderr("fatal: \(error.message)", exitCode: 128)
            }
        }
    }

    static func plan(
        client: SwiftGit.GitClient, remote explicit: String?, settings: Settings
    ) async throws -> Plan {
        let branch = try await client.currentBranch()
        func branchConfig(_ key: String) async throws -> String? {
            guard let branch else { return nil }
            return try await client.configGet("branch.\(branch).\(key)")
        }
        let upstreamRemote = try await branchConfig("remote")
        let upstreamMerge = try await branchConfig("merge")
        let remotes = try await client.remoteList()
        var remote = explicit
        if remote == nil { remote = try await branchConfig("pushRemote") }
        if remote == nil { remote = try await client.configGet("remote.pushDefault") }
        let fallback = RemoteArguments.defaultRemote(branchRemote: upstreamRemote, remotes: remotes)
        guard let target = remote ?? (fallback.isUsable ? fallback.name : nil), !target.isEmpty else {
            throw noPushDestination()
        }
        // git counts the remote pushed to among its remotes, a URL or path
        // too, so with no other remote it is the branch's remote as well.
        let fetchRemote = RemoteArguments.defaultRemote(
            branchRemote: upstreamRemote,
            remotes: remotes.contains(target) ? remotes : remotes + [target])

        if try await client.configGet("remote.\(target).push") != nil {
            return Plan(remote: target, refspecs: [], setUpstream: false)
        }
        let mode = settings.mode
        switch mode {
        case "matching":
            return Plan(remote: target, refspecs: [":"], setUpstream: false)
        case "nothing":
            throw CLIError.stderr(
                "fatal: You didn't specify any refspecs to push, and push.default is \"nothing\".",
                exitCode: 128)
        default:
            break
        }
        guard let branch else { throw detachedHead(remote: target) }

        let autoSetup = settings.autoSetupRemote
        let local = "refs/heads/\(branch)"
        // git's get_upstream_ref: the branch's upstream, else, when
        // push.autoSetupRemote is about to record one, the branch itself.
        func upstreamRef() throws -> String {
            if upstreamMerge == nil, autoSetup { return local }
            guard let upstreamMerge, upstreamRemote != nil else {
                throw noUpstream(branch: branch, remote: target, autoSetup: autoSetup)
            }
            return upstreamMerge
        }
        var destination = local
        switch mode {
        case "simple" where target == fetchRemote.name:
            let upstream = try upstreamRef()
            if upstream != local {
                throw upstreamNameMismatch(
                    remote: target, upstream: upstream,
                    pushDefaultAdvice: settings.configuredMode == nil,
                    autoSetupMergeAdvice: !settings.autoSetupMergeIsSimple)
            }
        case "upstream", "tracking":
            guard target == fetchRemote.name else {
                throw CLIError.stderr([
                    "fatal: You are pushing to remote '\(target)', which is not the upstream of",
                    "your current branch '\(branch)', without telling me what to push",
                    "to update which remote branch."
                ], exitCode: 128)
            }
            destination = try upstreamRef()
        default:
            // `current`, and `simple` pushing somewhere other than where
            // the branch pulls from (a triangular workflow): the branch
            // under its own name.
            break
        }
        return Plan(remote: target, refspecs: ["\(local):\(destination)"],
                    setUpstream: autoSetup && upstreamMerge == nil)
    }

    private static func noPushDestination() -> CLIError {
        CLIError.stderr([
            "fatal: No configured push destination.",
            "Either specify the URL from the command-line or configure a remote repository using",
            "",
            "    git remote add <name> <url>",
            "",
            "and then push using the remote name",
            "",
            "    git push <name>",
            ""
        ], exitCode: 128)
    }

    private static func detachedHead(remote: String) -> CLIError {
        CLIError.stderr([
            "fatal: You are not currently on a branch.",
            "To push the history leading to the current (detached HEAD)",
            "state now, use",
            "",
            "    git push \(remote) HEAD:<name-of-remote-branch>",
            ""
        ], exitCode: 128)
    }

    private static func noUpstream(branch: String, remote: String, autoSetup: Bool) -> CLIError {
        var lines = [
            "fatal: The current branch \(branch) has no upstream branch.",
            "To push the current branch and set the remote as upstream, use",
            "",
            "    git push --set-upstream \(remote) \(branch)"
        ]
        if !autoSetup {
            lines += [
                "",
                "To have this happen automatically for branches without a tracking",
                "upstream, see 'push.autoSetupRemote' in 'git help config'."
            ]
        }
        return CLIError.stderr(lines + [""], exitCode: 128)
    }

    private static func upstreamNameMismatch(
        remote: String, upstream: String, pushDefaultAdvice: Bool, autoSetupMergeAdvice: Bool
    ) -> CLIError {
        let short = upstream.hasPrefix("refs/heads/")
            ? String(upstream.dropFirst("refs/heads/".count)) : upstream
        var lines = [
            "fatal: The upstream branch of your current branch does not match",
            "the name of your current branch.  To push to the upstream branch",
            "on the remote, use",
            "",
            "    git push \(remote) HEAD:\(short)",
            "",
            "To push to the branch of the same name on the remote, use",
            "",
            "    git push \(remote) HEAD"
        ]
        if pushDefaultAdvice {
            lines += ["", "To choose either option permanently, see push.default in 'git help config'."]
        }
        if autoSetupMergeAdvice {
            lines += [
                "",
                "To avoid automatically configuring an upstream branch when its name",
                "won't match the local branch, see option 'simple' of branch.autoSetupMerge",
                "in 'git help config'."
            ]
        }
        return CLIError.stderr(lines + [""], exitCode: 128)
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

    /// The remote git takes for a branch when none is named
    /// (`remote_for_branch`): the branch's own remote, else the only one
    /// of `remotes`, else `origin`. Unlike a remote named on the command
    /// line or in the branch's config, the fallback `origin` has to be
    /// configured to be used: git never reads it as a path, so a
    /// repository in `./origin` is never pushed to or fetched from by
    /// accident. Nor is an empty name ever used.
    static func defaultRemote(
        branchRemote: String?, remotes: [String]
    ) -> (name: String, isUsable: Bool) {
        if let branchRemote { return (branchRemote, !branchRemote.isEmpty) }
        if remotes.count == 1 { return (remotes[0], true) }
        return ("origin", remotes.contains("origin"))
    }
}
