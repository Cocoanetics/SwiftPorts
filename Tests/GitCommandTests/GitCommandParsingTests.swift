#if !os(Android)  // argv-parsing test; ArgumentParser trips the Android explicit-module scanner
import Foundation
import Testing
import ArgumentParser
import ForgeKit
@testable import GitCommand

@Suite("GitCommand argv parsing")
struct GitCommandParsingTests {

    /// Resolve a subcommand from `["git", ...]` and return the parsed
    /// instance for assertion. Mirrors how ArgumentParser would dispatch
    /// at runtime.
    private func parse<T: ParsableCommand>(_ argv: [String], as type: T.Type) throws -> T {
        let parsed = try GitCommand.parseAsRoot(argv)
        let cmd = try #require(parsed as? T)
        return cmd
    }

    @Test("clone: URL only")
    func cloneURLOnly() throws {
        let cmd = try parse(["clone", "https://github.com/o/r.git"], as: Clone.self)
        #expect(cmd.url == "https://github.com/o/r.git")
        #expect(cmd.directory == nil)
    }

    @Test("clone: URL + directory")
    func cloneWithDirectory() throws {
        let cmd = try parse(
            ["clone", "https://github.com/o/r.git", "/tmp/r"], as: Clone.self)
        #expect(cmd.url == "https://github.com/o/r.git")
        #expect(cmd.directory == "/tmp/r")
    }

    @Test("fetch: defaults to origin")
    func fetchDefaultRemote() throws {
        let cmd = try parse(["fetch", "main"], as: Fetch.self)
        #expect(cmd.remote == "origin")
        #expect(cmd.refspec == "main")
    }

    @Test("fetch: --remote overrides default")
    func fetchExplicit() throws {
        let cmd = try parse(["fetch", "--remote", "upstream", "main"], as: Fetch.self)
        #expect(cmd.remote == "upstream")
        #expect(cmd.refspec == "main")
    }

    @Test("checkout: ref")
    func checkout() throws {
        let cmd = try parse(["checkout", "feature/x"], as: Checkout.self)
        let split = Checkout.split(cmd.rest)
        #expect(split.refs == ["feature/x"])
        #expect(split.paths.isEmpty)
    }

    @Test("push: bare refspec defaults to origin")
    func pushDefault() throws {
        let cmd = try parse(["push", "main"], as: Push.self)
        #expect(cmd.remote == "origin")
        #expect(cmd.refspec == "main")
        #expect(cmd.setUpstream == false)
    }

    @Test("push: -u sets upstream flag")
    func pushSetUpstreamShort() throws {
        let cmd = try parse(["push", "-u", "main"], as: Push.self)
        #expect(cmd.setUpstream == true)
        #expect(cmd.remote == "origin")
        #expect(cmd.refspec == "main")
    }

    @Test("push: --set-upstream + --remote long form")
    func pushSetUpstreamLong() throws {
        let cmd = try parse(
            ["push", "--set-upstream", "--remote", "upstream", "main"], as: Push.self)
        #expect(cmd.setUpstream == true)
        #expect(cmd.remote == "upstream")
        #expect(cmd.refspec == "main")
    }

    @Test("remote add: name + URL")
    func remoteAdd() throws {
        let cmd = try parse(
            ["remote", "add", "origin", "https://github.com/o/r.git"], as: RemoteAdd.self)
        #expect(cmd.name == "origin")
        #expect(cmd.url == "https://github.com/o/r.git")
    }

    @Test("remote get-url: name")
    func remoteGetURL() throws {
        let cmd = try parse(["remote", "get-url", "origin"], as: RemoteGetURL.self)
        #expect(cmd.name == "origin")
    }

    @Test("branch: --upstream")
    func branchUpstream() throws {
        let cmd = try parse(["branch", "--upstream", "main"], as: Branch.self)
        #expect(cmd.upstream == "main")
    }

    @Test("branch: --show-current")
    func branchShowCurrent() throws {
        let cmd = try parse(["branch", "--show-current"], as: Branch.self)
        #expect(cmd.showCurrent == true)
    }

    @Test("version: parses to VersionCommand")
    func version() throws {
        _ = try parse(["version"], as: VersionCommand.self)
    }

    @Test("commit: -m message")
    func commitMessage() throws {
        let cmd = try parse(["commit", "-m", "init"], as: Commit.self)
        #expect(cmd.message == "init")
        #expect(cmd.author == nil)
        #expect(cmd.allowEmpty == false)
    }

    @Test("commit: --message + --allow-empty")
    func commitAllowEmpty() throws {
        let cmd = try parse(
            ["commit", "--message", "stub", "--allow-empty"], as: Commit.self)
        #expect(cmd.message == "stub")
        #expect(cmd.allowEmpty == true)
    }

    @Test("commit: --author parses Name <email>")
    func commitAuthor() throws {
        let cmd = try parse(
            ["commit", "-m", "x", "--author", "Jane Doe <jane@example.com>"],
            as: Commit.self)
        let parsed = try Commit.parseAuthor(cmd.author ?? "")
        #expect(parsed.name == "Jane Doe")
        #expect(parsed.email == "jane@example.com")
    }

    @Test("commit: malformed --author rejected")
    func commitAuthorMalformed() {
        #expect(throws: (any Error).self) {
            _ = try Commit.parseAuthor("Jane Doe jane@example.com")
        }
    }

    @Test("add: -A stages everything")
    func addAll() throws {
        let cmd = try parse(["add", "-A"], as: Add.self)
        #expect(cmd.all == true)
        #expect(cmd.paths.isEmpty)
    }

    @Test("add: explicit paths")
    func addPaths() throws {
        let cmd = try parse(["add", "a.txt", "b.txt"], as: Add.self)
        #expect(cmd.all == false)
        #expect(cmd.force == false)
        #expect(cmd.paths == ["a.txt", "b.txt"])
    }

    @Test("add: -f sets force flag")
    func addForce() throws {
        let cmd = try parse(["add", "-f", "ignored.log"], as: Add.self)
        #expect(cmd.force == true)
        #expect(cmd.paths == ["ignored.log"])
    }

    @Test("add: bare invocation rejected at parse time")
    func addBareRejected() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["add"])
        }
    }

    @Test("add: -A with paths rejected at parse time")
    func addAllWithPathsRejected() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["add", "-A", "a.txt"])
        }
    }

    @Test("stash push: -m message + flags")
    func stashPushMessage() throws {
        let cmd = try parse(
            ["stash", "push", "-m", "wip", "-u", "--keep-index"], as: StashPush.self)
        #expect(cmd.message == "wip")
        #expect(cmd.includeUntracked == true)
        #expect(cmd.keepIndex == true)
        #expect(cmd.all == false)
    }

    @Test("stash defaults to push subcommand")
    func stashDefaultIsPush() throws {
        let cmd = try parse(["stash"], as: StashPush.self)
        #expect(cmd.message == nil)
        #expect(cmd.includeUntracked == false)
    }

    @Test("stash apply with index")
    func stashApplyIndexed() throws {
        let cmd = try parse(["stash", "apply", "stash@{2}"], as: StashApply.self)
        #expect(cmd.stash == "stash@{2}")
        let parsed = try parseStashIndex(cmd.stash)
        #expect(parsed == 2)
    }

    @Test("stash pop --index reinstates index")
    func stashPopIndex() throws {
        let cmd = try parse(["stash", "pop", "--index", "1"], as: StashPop.self)
        #expect(cmd.reinstateIndex == true)
        #expect(cmd.stash == "1")
        #expect(try parseStashIndex(cmd.stash) == 1)
    }

    @Test("stash branch: name + reference")
    func stashBranchParse() throws {
        let cmd = try parse(
            ["stash", "branch", "feature/wip", "stash@{0}"], as: StashBranch.self)
        #expect(cmd.name == "feature/wip")
        #expect(cmd.stash == "stash@{0}")
    }

    @Test("stash drop without arg defaults to 0")
    func stashDropDefault() throws {
        let cmd = try parse(["stash", "drop"], as: StashDrop.self)
        #expect(cmd.stash == nil)
        #expect(try parseStashIndex(cmd.stash) == 0)
    }

    @Test("invalid stash reference rejected")
    func stashIndexInvalid() {
        #expect(throws: (any Error).self) {
            _ = try parseStashIndex("stash@{abc}")
        }
        #expect(throws: (any Error).self) {
            _ = try parseStashIndex("garbage")
        }
    }

    @Test("diff: bare invocation parses cleanly")
    func diffBare() throws {
        let cmd = try parse(["diff"], as: Diff.self)
        #expect(cmd.cached == false)
        #expect(cmd.stat == false)
        #expect(cmd.rest.isEmpty)
    }

    @Test("diff: --cached")
    func diffCached() throws {
        let cmd = try parse(["diff", "--cached"], as: Diff.self)
        #expect(cmd.cached == true)
    }

    @Test("diff: --staged is an alias for --cached")
    func diffStaged() throws {
        let cmd = try parse(["diff", "--staged"], as: Diff.self)
        #expect(cmd.cached == true)
    }

    @Test("diff: --stat")
    func diffStat() throws {
        let cmd = try parse(["diff", "--stat"], as: Diff.self)
        #expect(cmd.stat == true)
    }

    @Test("diff: --name-only / --name-status")
    func diffNameForms() throws {
        let only = try parse(["diff", "--name-only"], as: Diff.self)
        #expect(only.nameOnly == true)
        let status = try parse(["diff", "--name-status"], as: Diff.self)
        #expect(status.nameStatus == true)
    }

    @Test("diff: positional refs collected in rest")
    func diffPositionalRefs() throws {
        let cmd = try parse(["diff", "HEAD~1", "HEAD"], as: Diff.self)
        let split = try Diff.split(cmd.rest)
        #expect(split.refs == ["HEAD~1", "HEAD"])
        #expect(split.paths.isEmpty)
    }

    @Test("diff: -- splits refs from paths")
    func diffPathSeparator() throws {
        let cmd = try parse(["diff", "main", "--", "a.txt", "b.txt"], as: Diff.self)
        let split = try Diff.split(cmd.rest)
        #expect(split.refs == ["main"])
        #expect(split.paths == ["a.txt", "b.txt"])
    }

    @Test("diff: --shortstat / --numstat / --raw / -p flags")
    func diffNewFormatFlags() throws {
        #expect(try parse(["diff", "--shortstat"], as: Diff.self).shortStat == true)
        #expect(try parse(["diff", "--numstat"], as: Diff.self).numStat == true)
        #expect(try parse(["diff", "--raw"], as: Diff.self).raw == true)
        #expect(try parse(["diff", "-p"], as: Diff.self).patch == true)
    }

    // MARK: - bare `--color` normalization (GitCommand.preprocess)

    @Test("preprocess: bare --color → --color=always for diff / status")
    func preprocessBareColor() {
        #expect(GitCommand.preprocess(["diff", "--color"]) == ["diff", "--color=always"])
        #expect(GitCommand.preprocess(["status", "--color"]) == ["status", "--color=always"])
    }

    @Test("preprocess: --color=<when> is left untouched")
    func preprocessColorWithValueUntouched() {
        #expect(GitCommand.preprocess(["diff", "--color=never"]) == ["diff", "--color=never"])
        #expect(GitCommand.preprocess(["diff", "--color=auto"]) == ["diff", "--color=auto"])
    }

    @Test("preprocess: --color after -- stays a pathspec")
    func preprocessColorAfterDoubleDash() {
        #expect(GitCommand.preprocess(["diff", "--", "--color"]) == ["diff", "--", "--color"])
        #expect(
            GitCommand.preprocess(["diff", "--color", "--", "--color"])
                == ["diff", "--color=always", "--", "--color"])
    }

    @Test("preprocess: non-color subcommands pass through unchanged")
    func preprocessOtherSubcommands() {
        #expect(GitCommand.preprocess(["log", "--color"]) == ["log", "--color"])
        #expect(GitCommand.preprocess(["commit", "-m", "x"]) == ["commit", "-m", "x"])
    }

    @Test("diff: bare --color parses to .always, ref kept as a revision")
    func diffBareColorParses() throws {
        let cmd = try parse(GitCommand.preprocess(["diff", "--color"]), as: Diff.self)
        #expect(cmd.color == .always)
        // A following ref must NOT be swallowed as the color value.
        let withRef = try parse(
            GitCommand.preprocess(["diff", "--color", "HEAD"]), as: Diff.self)
        #expect(withRef.color == .always)
        #expect(withRef.rest == ["HEAD"])
    }

    @Test("diff: --color=never / status bare --color parse correctly")
    func diffStatusColorValues() throws {
        #expect(try parse(["diff", "--color=never"], as: Diff.self).color == .never)
        let status = try parse(
            GitCommand.preprocess(["status", "--color"]), as: Status.self)
        #expect(status.color == .always)
    }

    @Test("diff: --unified / -U <n>")
    func diffUnifiedFlag() throws {
        let long = try parse(["diff", "--unified", "5"], as: Diff.self)
        #expect(long.unified == 5)
        let short = try parse(["diff", "-U", "0"], as: Diff.self)
        #expect(short.unified == 0)
    }

    @Test("diff: a..b expands to two refs (asymmetric)")
    func diffRangeAsymmetric() throws {
        let (refs, sym) = try Diff.expandRanges(["HEAD~1..HEAD"])
        #expect(refs == ["HEAD~1", "HEAD"])
        #expect(sym == false)
    }

    @Test("diff: a...b expands to two refs (symmetric)")
    func diffRangeSymmetric() throws {
        let (refs, sym) = try Diff.expandRanges(["main...feature"])
        #expect(refs == ["main", "feature"])
        #expect(sym == true)
    }

    @Test("diff: invalid range rejected")
    func diffRangeInvalid() {
        #expect(throws: (any Error).self) {
            _ = try Diff.expandRanges(["..HEAD"])
        }
        #expect(throws: (any Error).self) {
            _ = try Diff.expandRanges(["HEAD.."])
        }
    }

    @Test("diff: multiple ranges rejected")
    func diffMultipleRanges() {
        #expect(throws: (any Error).self) {
            _ = try Diff.expandRanges(["a..b", "c..d"])
        }
    }

    @Test("merge: ref + --no-ff")
    func mergeNoFF() throws {
        let cmd = try parse(["merge", "--no-ff", "feature"], as: Merge.self)
        #expect(cmd.noFF == true)
        #expect(cmd.ref == "feature")
    }

    @Test("merge: --ff-only")
    func mergeFFOnly() throws {
        let cmd = try parse(["merge", "--ff-only", "feature"], as: Merge.self)
        #expect(cmd.ffOnly == true)
    }

    @Test("merge: rejects multiple ff modes")
    func mergeFFModesExclusive() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["merge", "--no-ff", "--ff-only", "feature"])
        }
    }

    @Test("pull: defaults remote to origin")
    func pullDefaults() throws {
        let cmd = try parse(["pull"], as: Pull.self)
        #expect(cmd.remote == "origin")
        #expect(cmd.branch == nil)
    }

    @Test("pull: explicit remote + branch")
    func pullExplicit() throws {
        let cmd = try parse(["pull", "upstream", "main"], as: Pull.self)
        #expect(cmd.remote == "upstream")
        #expect(cmd.branch == "main")
    }

    @Test("pull: --no-ff carried through")
    func pullNoFF() throws {
        let cmd = try parse(["pull", "--no-ff"], as: Pull.self)
        #expect(cmd.noFF == true)
    }

    @Test("rebase: <upstream>")
    func rebaseUpstream() throws {
        let cmd = try parse(["rebase", "main"], as: Rebase.self)
        #expect(cmd.upstream == "main")
        #expect(cmd.continueRebase == false)
        #expect(cmd.abort == false)
    }

    @Test("rebase: --onto NEWBASE upstream")
    func rebaseOnto() throws {
        let cmd = try parse(
            ["rebase", "--onto", "main", "feature~3"], as: Rebase.self)
        #expect(cmd.onto == "main")
        #expect(cmd.upstream == "feature~3")
    }

    @Test("rebase: --continue")
    func rebaseContinue() throws {
        let cmd = try parse(["rebase", "--continue"], as: Rebase.self)
        #expect(cmd.continueRebase == true)
    }

    @Test("rebase: --abort")
    func rebaseAbort() throws {
        let cmd = try parse(["rebase", "--abort"], as: Rebase.self)
        #expect(cmd.abort == true)
    }

    @Test("rebase: --continue and --abort mutually exclusive")
    func rebaseContinueAbortExclusive() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["rebase", "--continue", "--abort"])
        }
    }

    @Test("rebase: bare invocation rejected (needs upstream)")
    func rebaseBareRejected() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["rebase"])
        }
    }

    @Test("rebase: --abort + upstream rejected")
    func rebaseAbortWithUpstream() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["rebase", "--abort", "main"])
        }
    }

    @Test("rebase: --skip")
    func rebaseSkip() throws {
        let cmd = try parse(["rebase", "--skip"], as: Rebase.self)
        #expect(cmd.skip == true)
        #expect(cmd.continueRebase == false)
        #expect(cmd.abort == false)
    }

    @Test("rebase: --skip + --continue mutually exclusive")
    func rebaseSkipContinueExclusive() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["rebase", "--skip", "--continue"])
        }
    }

    @Test("pull: --rebase")
    func pullRebase() throws {
        let cmd = try parse(["pull", "--rebase"], as: Pull.self)
        #expect(cmd.rebase == true)
    }

    @Test("pull: -r short form for --rebase")
    func pullRebaseShort() throws {
        let cmd = try parse(["pull", "-r"], as: Pull.self)
        #expect(cmd.rebase == true)
    }

    @Test("pull: --rebase + --no-ff rejected")
    func pullRebaseFFExclusive() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["pull", "--rebase", "--no-ff"])
        }
    }

    @Test("reset: --soft <commit>")
    func resetSoftParse() throws {
        let cmd = try parse(["reset", "--soft", "HEAD~1"], as: Reset.self)
        #expect(cmd.soft == true)
        #expect(cmd.rest == ["HEAD~1"])
        let split = Reset.split(cmd.rest)
        #expect(split.commit == "HEAD~1")
        #expect(split.paths.isEmpty)
    }

    @Test("reset: -- <paths> (per-path form)")
    func resetPerPathParse() throws {
        let cmd = try parse(
            ["reset", "HEAD", "--", "a.txt", "b.txt"], as: Reset.self)
        let split = Reset.split(cmd.rest)
        #expect(split.commit == "HEAD")
        #expect(split.paths == ["a.txt", "b.txt"])
    }

    @Test("reset: --soft / --hard mutually exclusive")
    func resetModeMutex() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["reset", "--soft", "--hard", "HEAD"])
        }
    }

    @Test("checkout: -b <name>")
    func checkoutNewBranchParse() throws {
        let cmd = try parse(["checkout", "-b", "feature"], as: Checkout.self)
        #expect(cmd.newBranch == "feature")
        #expect(cmd.forceBranch == nil)
    }

    @Test("checkout: -B <name>")
    func checkoutForceBranchParse() throws {
        let cmd = try parse(["checkout", "-B", "feature"], as: Checkout.self)
        #expect(cmd.forceBranch == "feature")
        #expect(cmd.newBranch == nil)
    }

    @Test("checkout: -b + start-point")
    func checkoutNewBranchWithStartPoint() throws {
        let cmd = try parse(
            ["checkout", "-b", "feat", "main"], as: Checkout.self)
        #expect(cmd.newBranch == "feat")
        let split = Checkout.split(cmd.rest)
        #expect(split.refs == ["main"])
    }

    @Test("checkout: -- <paths>")
    func checkoutPathsParse() throws {
        let cmd = try parse(
            ["checkout", "--", "a.txt", "b.txt"], as: Checkout.self)
        let split = Checkout.split(cmd.rest)
        #expect(split.refs.isEmpty)
        #expect(split.paths == ["a.txt", "b.txt"])
    }

    @Test("checkout: <ref> -- <paths>")
    func checkoutRefAndPathsParse() throws {
        let cmd = try parse(
            ["checkout", "main", "--", "a.txt"], as: Checkout.self)
        let split = Checkout.split(cmd.rest)
        #expect(split.refs == ["main"])
        #expect(split.paths == ["a.txt"])
    }

    @Test("checkout: -b and -B mutually exclusive")
    func checkoutBranchFlagsMutex() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["checkout", "-b", "x", "-B", "y"])
        }
    }

    @Test("cherry-pick: <commit>")
    func cherryPickCommitParse() throws {
        let cmd = try parse(["cherry-pick", "HEAD~1"], as: CherryPick.self)
        #expect(cmd.commit == "HEAD~1")
    }

    @Test("cherry-pick: --continue / --abort / --skip mutually exclusive")
    func cherryPickResumeMutex() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(
                ["cherry-pick", "--continue", "--abort"])
        }
    }

    @Test("cherry-pick: bare invocation rejected (needs <commit>)")
    func cherryPickBareRejected() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["cherry-pick"])
        }
    }

    @Test("cherry-pick: --abort + commit rejected")
    func cherryPickAbortWithCommit() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["cherry-pick", "--abort", "HEAD"])
        }
    }

    @Test("status: bare invocation parses cleanly")
    func statusBare() throws {
        let cmd = try parse(["status"], as: Status.self)
        #expect(cmd.short == false)
        #expect(cmd.porcelain == false)
        #expect(cmd.branch == false)
    }

    @Test("status: -s / --short flag")
    func statusShortFlag() throws {
        #expect(try parse(["status", "-s"], as: Status.self).short == true)
        #expect(try parse(["status", "--short"], as: Status.self).short == true)
    }

    @Test("status: --porcelain flag")
    func statusPorcelainFlag() throws {
        let cmd = try parse(["status", "--porcelain"], as: Status.self)
        #expect(cmd.porcelain == true)
    }

    @Test("status: -b / --branch flag")
    func statusBranchFlag() throws {
        #expect(try parse(["status", "-b"], as: Status.self).branch == true)
        #expect(try parse(["status", "--branch"], as: Status.self).branch == true)
    }

    @Test("status: -sb combined flags")
    func statusCombinedFlags() throws {
        let cmd = try parse(["status", "-sb"], as: Status.self)
        #expect(cmd.short == true)
        #expect(cmd.branch == true)
    }

    @Test("log: bare invocation parses cleanly")
    func logBare() throws {
        let cmd = try parse(["log"], as: Log.self)
        #expect(cmd.oneline == false)
        #expect(cmd.maxCount == nil)
        #expect(cmd.rest.isEmpty)
    }

    @Test("log: --oneline + -n 3")
    func logOnelineLimit() throws {
        let cmd = try parse(["log", "--oneline", "-n", "3"], as: Log.self)
        #expect(cmd.oneline == true)
        #expect(cmd.maxCount == 3)
    }

    @Test("log: bare -1 captured as passthrough (Entry.swift would rewrite)")
    func logDashOneLandsInRest() throws {
        // When `git log -1` is invoked as a standalone binary, the
        // Entry preprocessor rewrites `-1` → `-n 1` before parsing.
        // When it's invoked as a SwiftBash builtin (parseAsRoot is
        // called directly), `-1` is captured into `rest` for `run()`
        // to re-interpret. Verify the latter shape so the run-time
        // pull-out logic in Log.run has something to find.
        let cmd = try parse(["log", "--oneline", "-1"], as: Log.self)
        #expect(cmd.oneline == true)
        #expect(cmd.rest == ["-1"])
    }

    @Test("log: --format passes through")
    func logFormatParse() throws {
        let cmd = try parse(["log", "--format", "%H%n%s"], as: Log.self)
        #expect(cmd.format == "%H%n%s")
    }

    @Test("log: --stat + -p flags")
    func logStatPatch() throws {
        #expect(try parse(["log", "--stat"], as: Log.self).stat == true)
        #expect(try parse(["log", "-p"], as: Log.self).patch == true)
        #expect(try parse(["log", "--patch"], as: Log.self).patch == true)
    }

    @Test("log: range expands to (starts, excludes)")
    func logRangeExpansion() throws {
        let (starts, excludes) = try Log.expandRefs(["HEAD~3..HEAD"])
        #expect(starts == ["HEAD"])
        #expect(excludes == ["HEAD~3"])
    }

    @Test("log: ^<ref> form excludes")
    func logCaretExclude() throws {
        let (starts, excludes) = try Log.expandRefs(["HEAD", "^main"])
        #expect(starts == ["HEAD"])
        #expect(excludes == ["main"])
    }

    @Test("log: -- splits refs from paths")
    func logSplitOnDoubleDash() throws {
        let (refs, paths) = Log.splitOnDoubleDash(["HEAD", "--", "a.txt"])
        #expect(refs == ["HEAD"])
        #expect(paths == ["a.txt"])
    }

    @Test("log: pullPassthrough — -<n> pulled before --")
    func logPullPassthroughDashNBeforeDoubleDash() throws {
        let result = Log.pullPassthrough(
            rest: ["--oneline", "-1"],
            oneline: false, stat: false, patch: false,
            format: nil, maxCount: nil)
        #expect(result.oneline == true)
        #expect(result.maxCount == 1)
        #expect(result.positionals.isEmpty)
    }

    @Test("log: pullPassthrough — -<n> after -- stays as path")
    func logPullPassthroughDashNAfterDoubleDash() throws {
        // `git log -- -1` filters to a file literally named `-1`; the
        // `-<n>` shorthand must not be applied past the `--` separator.
        let result = Log.pullPassthrough(
            rest: ["--", "-1"],
            oneline: false, stat: false, patch: false,
            format: nil, maxCount: nil)
        #expect(result.maxCount == nil)
        #expect(result.positionals == ["--", "-1"])
    }

    @Test("log: pullPassthrough — flag-shaped path after -- stays as path")
    func logPullPassthroughFlagShapedPathAfterDoubleDash() throws {
        // Any flag-shaped token after `--` is a pathspec, not a flag.
        let result = Log.pullPassthrough(
            rest: ["HEAD", "--", "--oneline", "--stat"],
            oneline: false, stat: false, patch: false,
            format: nil, maxCount: nil)
        #expect(result.oneline == false)
        #expect(result.stat == false)
        #expect(result.positionals == ["HEAD", "--", "--oneline", "--stat"])
    }

    @Test("tag: bare lists")
    func tagBareList() throws {
        let cmd = try parse(["tag"], as: Tag.self)
        #expect(cmd.delete == false)
        #expect(cmd.annotate == false)
    }

    @Test("tag: -a -m annotated")
    func tagAnnotateParse() throws {
        let cmd = try parse(["tag", "-a", "v1.0", "-m", "rel"], as: Tag.self)
        #expect(cmd.annotate == true)
    }

    @Test("tag: -d delete")
    func tagDeleteParse() throws {
        let cmd = try parse(["tag", "-d", "v1.0"], as: Tag.self)
        #expect(cmd.delete == true)
    }

    @Test("tag: -n with annotation listing")
    func tagAnnotationListing() throws {
        let cmd = try parse(["tag", "-n"], as: Tag.self)
        #expect(cmd.withAnnotation == true)
    }

    @Test("rev-parse: --short HEAD")
    func revParseShort() throws {
        let cmd = try parse(["rev-parse", "--short", "HEAD"], as: RevParse.self)
        #expect(cmd.short == true)
        #expect(cmd.specs == ["HEAD"])
    }

    @Test("rev-parse: --git-dir / --is-inside-work-tree")
    func revParseFlags() throws {
        #expect(try parse(["rev-parse", "--git-dir"], as: RevParse.self).gitDir == true)
        #expect(try parse(["rev-parse", "--is-inside-work-tree"], as: RevParse.self).isInsideWorkTree == true)
    }

    @Test("show: bare and ref")
    func showParse() throws {
        #expect(try parse(["show"], as: Show.self).spec == nil)
        #expect(try parse(["show", "HEAD~1"], as: Show.self).spec == "HEAD~1")
    }

    @Test("mv: source + destination")
    func mvParse() throws {
        let cmd = try parse(["mv", "old.txt", "new.txt"], as: Mv.self)
        #expect(cmd.source == "old.txt")
        #expect(cmd.destination == "new.txt")
    }

    @Test("rm: --cached + paths")
    func rmCachedParse() throws {
        let cmd = try parse(["rm", "--cached", "a.txt", "b.txt"], as: Rm.self)
        #expect(cmd.cached == true)
        #expect(cmd.paths == ["a.txt", "b.txt"])
    }

    @Test("config: --global write form")
    func configGlobalSet() throws {
        let cmd = try parse(["config", "--global", "user.email", "x@y.z"], as: Config.self)
        #expect(cmd.global == true)
        #expect(cmd.args == ["user.email", "x@y.z"])
    }

    @Test("config: --list flag")
    func configList() throws {
        #expect(try parse(["config", "--list"], as: Config.self).list == true)
        #expect(try parse(["config", "-l"], as: Config.self).list == true)
    }

    @Test("switch: -c new branch")
    func switchCreate() throws {
        let cmd = try parse(["switch", "-c", "feat"], as: Switch.self)
        #expect(cmd.create == "feat")
    }

    @Test("switch: -C force-create")
    func switchForceCreate() throws {
        let cmd = try parse(["switch", "-C", "feat"], as: Switch.self)
        #expect(cmd.forceCreate == "feat")
    }

    @Test("restore: --staged + paths")
    func restoreStagedParse() throws {
        let cmd = try parse(["restore", "--staged", "a.txt"], as: Restore.self)
        #expect(cmd.staged == true)
        #expect(cmd.paths == ["a.txt"])
    }

    @Test("restore: --source + paths")
    func restoreSourceParse() throws {
        let cmd = try parse(["restore", "--source", "HEAD~1", "a.txt"], as: Restore.self)
        #expect(cmd.source == "HEAD~1")
    }

    @Test("clean: -n dry-run")
    func cleanDryRun() throws {
        let cmd = try parse(["clean", "-n"], as: Clean.self)
        #expect(cmd.dryRun == true)
    }

    @Test("ls-files: bare invocation")
    func lsFilesBare() throws {
        _ = try parse(["ls-files"], as: LsFiles.self)
    }

    @Test("grep: pattern + paths")
    func grepPatternAndPaths() throws {
        let cmd = try parse(["grep", "TODO", "src", "docs"], as: Grep.self)
        #expect(cmd.pattern == "TODO")
        #expect(cmd.paths == ["src", "docs"])
        #expect(cmd.ignoreCase == false)
        #expect(cmd.lineNumber == false)
    }

    @Test("grep: -i -n short flags")
    func grepShortFlags() throws {
        let cmd = try parse(["grep", "-i", "-n", "needle"], as: Grep.self)
        #expect(cmd.pattern == "needle")
        #expect(cmd.ignoreCase == true)
        #expect(cmd.lineNumber == true)
    }

    @Test("grep: -l and -c are independent flags")
    func grepOutputModeFlags() throws {
        let nameOnly = try parse(["grep", "-l", "x"], as: Grep.self)
        #expect(nameOnly.nameOnly == true)
        let count = try parse(["grep", "-c", "x"], as: Grep.self)
        #expect(count.count == true)
    }

    @Test("grep: --untracked extends the search to untracked-not-ignored")
    func grepUntrackedFlag() throws {
        let cmd = try parse(["grep", "--untracked", "x"], as: Grep.self)
        #expect(cmd.untracked == true)
    }

    @Test("missing subcommand exits non-zero")
    func missingSubcommandFails() {
        #expect(throws: (any Error).self) {
            _ = try GitCommand.parseAsRoot(["bogus"])
        }
    }

    @Test("init: bare invocation initializes the cwd")
    func initBare() throws {
        let cmd = try parse(["init"], as: GitInit.self)
        #expect(cmd.bare == false)
        #expect(cmd.directory == nil)
        #expect(cmd.initialBranch == nil)
    }

    @Test("init: --bare + -b <branch> + directory")
    func initFullForm() throws {
        let cmd = try parse(
            ["init", "--bare", "-b", "main", "/tmp/r"],
            as: GitInit.self)
        #expect(cmd.bare == true)
        #expect(cmd.initialBranch == "main")
        #expect(cmd.directory == "/tmp/r")
    }

    @Test("describe: defaults to HEAD with annotated-only matches")
    func describeDefaults() throws {
        let cmd = try parse(["describe"], as: Describe.self)
        #expect(cmd.committish == "HEAD")
        #expect(cmd.tags == false)
        #expect(cmd.dirty == false)
        #expect(cmd.abbrev == 7)
    }

    @Test("describe: --tags + --dirty + custom abbrev + ref")
    func describeFullForm() throws {
        let cmd = try parse(
            ["describe", "--tags", "--dirty", "--abbrev", "10", "feature/x"],
            as: Describe.self)
        #expect(cmd.tags == true)
        #expect(cmd.dirty == true)
        #expect(cmd.abbrev == 10)
        #expect(cmd.committish == "feature/x")
    }

    @Test("ls-tree: defaults to HEAD, non-recursive")
    func lsTreeDefaults() throws {
        let cmd = try parse(["ls-tree"], as: LsTree.self)
        #expect(cmd.treeish == "HEAD")
        #expect(cmd.recursive == false)
        #expect(cmd.nameOnly == false)
    }

    @Test("ls-tree: -r + --name-only + ref")
    func lsTreeRecursive() throws {
        let cmd = try parse(
            ["ls-tree", "-r", "--name-only", "main"],
            as: LsTree.self)
        #expect(cmd.recursive == true)
        #expect(cmd.nameOnly == true)
        #expect(cmd.treeish == "main")
    }

    @Test("cat-file: -t HEAD")
    func catFileType() throws {
        let cmd = try parse(["cat-file", "-t", "HEAD"], as: CatFile.self)
        #expect(cmd.typeOnly == true)
        #expect(cmd.object == "HEAD")
    }

    @Test("cat-file: -p with SHA")
    func catFilePretty() throws {
        let cmd = try parse(
            ["cat-file", "-p", "abc123"], as: CatFile.self)
        #expect(cmd.pretty == true)
        #expect(cmd.object == "abc123")
    }
}

#endif  // !os(Android)
