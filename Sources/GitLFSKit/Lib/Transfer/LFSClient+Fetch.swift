import Foundation
import SwiftGit

extension LFSClient {
    /// `git lfs fetch` (git-lfs 3.7.1 `commands/command_fetch.go`) without
    /// `--recent`, `--prune` or `--refetch`.
    ///
    /// Without `all`, each ref's tip tree is scanned in turn (`refs` empty: the
    /// current ref), under `include` / `exclude` when given and
    /// `lfs.fetchinclude` / `lfs.fetchexclude` otherwise, each side on its
    /// own. Refs are named as git-lfs prints them (`Ref.Refspec`, e.g.
    /// `refs/heads/main`). `all` scans every object reachable from `refs`, or
    /// from every ref when `refs` is empty, and refuses `include` / `exclude`.
    /// Objects already in the local store are not requested.
    ///
    /// `dryRun` still asks the batch API which objects the server has, but
    /// transfers none and prints `fetch <oid> => <path>` for each. `json`
    /// prints the transferred objects as `{"transfers": […]}` on success
    /// and suppresses the progress meter. `terminal` says whether stdout is
    /// a terminal, for the meter and the scan's object count.
    public func fetch(
        refs: [String] = [], remote: String = "", include: String? = nil, exclude: String? = nil,
        all: Bool = false, dryRun: Bool = false, json: Bool = false, terminal: Bool = false,
        git: GitClient
    ) async throws -> LFSCommandResult {
        try await fetch(refs: refs, remote: remote, include: include, exclude: exclude, all: all,
                        dryRun: dryRun, json: json, terminal: terminal, git: git,
                        environment: LFSTransferEnvironment())
    }

    // swiftlint:disable:next function_parameter_count
    func fetch(
        refs: [String], remote: String, include: String?, exclude: String?, all: Bool,
        dryRun: Bool, json: Bool, terminal: Bool, git: GitClient, environment: LFSTransferEnvironment
    ) async throws -> LFSCommandResult {
        let config = finder.configuration
        let remote = remote.isEmpty ? await finder.downloadRemote() : remote
        var run = LFSFetchRun(
            client: self, git: git, store: try await LocalStore.open(git), remote: remote,
            dryRun: dryRun, json: json, terminal: terminal, environment: environment)
        var success = true
        if all {
            if include != nil || exclude != nil {
                run.result.fail("Cannot combine --all with --include or --exclude")
                return run.result
            }
            if !config.fetchPaths("lfs.fetchinclude").isEmpty || !config.fetchPaths("lfs.fetchexclude").isEmpty {
                run.result.stderr += "Ignoring global include / exclude paths to fulfil --all\n"
            }
            let scanner = GitScanner(client: git)
            guard let pointers = await run.scan(counting: true, {
                refs.isEmpty ? try await scanner.scanAll() : try await scanner.scanRefs(include: refs)
            }) else { return run.result }
            if refs.isEmpty { run.result.stderr += "Fetching all references...\n" }
            success = try await run.fetch(pointers)
        } else {
            let filter = FilepathFilter(
                include: include.map(LFSConfiguration.cleanPaths) ?? config.fetchPaths("lfs.fetchinclude"),
                exclude: exclude.map(LFSConfiguration.cleanPaths) ?? config.fetchPaths("lfs.fetchexclude"))
            let scanner = GitScanner(client: git, filter: filter)
            let refs = refs.isEmpty ? [await Self.currentRef(git)] : refs
            for ref in refs {
                run.result.stderr += "Fetching reference \(ref)\n"
                guard let pointers = await run.scan(counting: false, { try await scanner.scanTree(ref) })
                else { return run.result }
                let fetched = try await run.fetch(pointers)
                success = success && fetched
            }
        }
        if !success {
            let url = finder.endpoint(operation: "download", remote: remote).url
            run.result.fail("error: failed to fetch some objects from '\(url)'")
            return run.result
        }
        if json { run.result.stdout += run.watcher.dumpJSON() }
        return run.result
    }

    /// `git.CurrentRef().Refspec()`: the checked-out branch, or `HEAD` when detached.
    static func currentRef(_ git: GitClient) async -> String {
        guard let branch = try? await git.currentBranch(), !branch.isEmpty else { return "HEAD" }
        return "refs/heads/" + branch
    }
}
