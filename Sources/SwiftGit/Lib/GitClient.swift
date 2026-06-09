import Foundation
import ForgeKit
import ShellKit
import libgit2

/// In-process libgit2-backed implementation of
/// ``ForgeKit/GitClient`` (the protocol). The simple name `GitClient`
/// is reserved here in `SwiftGit` for the canonical concrete client;
/// the `ForgeKit` protocol is referred to in fully-qualified form
/// below to disambiguate.
///
/// Drop-in replacement for `ProcessGitClient` that doesn't need a `git`
/// binary on `PATH`. Works on macOS / iOS / tvOS / watchOS — anywhere
/// libgit2 builds.
///
/// Caveats vs the user's system git: HTTPS auth uses libgit2's built-in
/// http parser + SecureTransport; SSH auth uses libgit2's `GIT_SSH_EXEC`
/// path which still shells out to the system `ssh`. Neither honours the
/// user's `gitconfig` `credential.helper` — for token-bearing pushes,
/// embed the token in the URL or call `addRemote` with one.
public struct GitClient: ForgeKit.GitClient {
    public let workingDirectory: URL
    public let credentials: CredentialProvider?

    public init(
        workingDirectory: URL = Shell.currentDirectory,
        credentials: CredentialProvider? = nil
    ) {
        Libgit2.ensureInitialized()
        self.workingDirectory = workingDirectory
        self.credentials = credentials
    }

    // MARK: Read

    public func remoteURL(named name: String) async throws -> URL? {
        try await withRepository { repo in
            var remote: OpaquePointer?
            let rc = git_remote_lookup(&remote, repo, name)
            if rc == GIT_ENOTFOUND.rawValue { return nil }
            try check(rc)
            defer { git_remote_free(remote) }

            guard let cstr = git_remote_url(remote) else { return nil }
            let str = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
            return str.isEmpty ? nil : URL(string: str)
        }
    }

    public func currentBranch() async throws -> String? {
        try await withRepository { repo in
            var head: OpaquePointer?
            let rc = git_repository_head(&head, repo)
            // Unborn (no commits yet) or detached HEAD → no current branch.
            if rc == GIT_EUNBORNBRANCH.rawValue || rc == GIT_ENOTFOUND.rawValue {
                return nil
            }
            try check(rc)
            defer { git_reference_free(head) }

            guard let cstr = git_reference_shorthand(head) else { return nil }
            let name = String(cString: cstr)
            // `git_reference_shorthand` returns "HEAD" when detached.
            return name == "HEAD" ? nil : name
        }
    }

    public func upstreamBranch(of localBranch: String) async throws -> String? {
        try await withRepository { repo in
            // Resolve the local branch shorthand into its full refname.
            var branch: OpaquePointer?
            let lookupRC = git_branch_lookup(&branch, repo, localBranch, GIT_BRANCH_LOCAL)
            if lookupRC == GIT_ENOTFOUND.rawValue { return nil }
            try check(lookupRC)
            defer { git_reference_free(branch) }

            guard let refName = git_reference_name(branch) else { return nil }

            var buf = git_buf()
            let rc = git_branch_upstream_name(&buf, repo, refName)
            if rc == GIT_ENOTFOUND.rawValue { return nil }
            try check(rc)
            defer { git_buf_dispose(&buf) }

            guard let ptr = buf.ptr else { return nil }
            // Returns the full upstream refname, e.g. "refs/remotes/origin/main".
            // Strip the "refs/remotes/" prefix to mirror the
            // `git rev-parse --abbrev-ref --symbolic-full-name @{upstream}` output.
            let full = String(cString: ptr)
            let prefix = "refs/remotes/"
            return full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : full
        }
    }

    // MARK: Write

    public func clone(url: URL, directory: URL?) async throws {
        // Gate the clone source URL (file or network) and the
        // destination directory before handing them to libgit2.
        // libgit2's internal HTTP/SSH and packfile FS ops are below
        // this Swift boundary and are not gated by v1 — see #15
        // open-question § 5.6.
        try await Shell.authorize(url)
        let destURL = directory ?? defaultCloneDirectory(for: url)
        try await Shell.authorize(destURL)
        // Tier-2 (#18): apply env→option bridge before clone so the
        // freshly-init'd repo's config is loaded against the sandbox.
        try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
            try cloneInner(url: url, dest: destURL.path)
        }
    }

    private func cloneInner(url: URL, dest: String) throws {
        Libgit2.ensureInitialized()

        var opts = git_clone_options()
        try check(git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION)))

        var reporter = ProgressReporter(
            headerURL: url.absoluteString, direction: .fetch)
        // Real git's local clone (file:// or bare path) skips the
        // `remote: …` / `Receiving objects: …` lines — match it.
        reporter.suppressTransferProgress =
            ProgressReporter.isLocalURL(url.absoluteString)

        try withCallbacksPayload(
            credentials: credentials, reporter: reporter,
            { credCB, sidebandCB, transferCB, _, _, _, _, payload in
                opts.fetch_opts.callbacks.credentials = credCB
                opts.fetch_opts.callbacks.sideband_progress = sidebandCB
                opts.fetch_opts.callbacks.transfer_progress = transferCB
                opts.fetch_opts.callbacks.payload = payload

                var repo: OpaquePointer?
                try check(git_clone(&repo, url.absoluteString, dest, &opts))
                git_repository_free(repo)
            },
            outReporter: { reporter = $0 })
        // No `From`/per-ref block on clone — real git just prints
        // `Cloning into '…'` (handled by the CLI subcommand) plus the
        // transfer progress lines we already emitted.
    }

    public func fetch(remote: String, refspec: String) async throws {
        try await withRepository { repo in
            var remoteHandle: OpaquePointer?
            try check(git_remote_lookup(&remoteHandle, repo, remote))
            defer { git_remote_free(remoteHandle) }

            // Pull the remote URL out of the handle for the `From <url>` header.
            let remoteURL = git_remote_url(remoteHandle).map { String(cString: $0) }
            var reporter = ProgressReporter(
                headerURL: remoteURL, direction: .fetch)
            reporter.suppressTransferProgress =
                ProgressReporter.isLocalURL(remoteURL)

            try refspec.withCString { cstr in
                var copy: UnsafeMutablePointer<CChar>? = strdup(cstr)
                defer { free(copy) }
                try withUnsafeMutablePointer(to: &copy) { copyPtr in
                    var arr = git_strarray(strings: copyPtr, count: 1)
                    var opts = git_fetch_options()
                    try check(git_fetch_options_init(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION)))
                    try withCallbacksPayload(
                        credentials: credentials, reporter: reporter,
                        { credCB, sidebandCB, transferCB, updateCB, _, _, _, payload in
                            opts.callbacks.credentials = credCB
                            opts.callbacks.sideband_progress = sidebandCB
                            opts.callbacks.transfer_progress = transferCB
                            // `update_refs` is the modern slot; libgit2
                            // treats both update_refs and update_tips as
                            // valid but prefers update_refs.
                            opts.callbacks.update_refs = updateCB
                            opts.callbacks.payload = payload
                            try check(git_remote_fetch(remoteHandle, &arr, &opts, nil))
                        },
                        outReporter: { reporter = $0 })
                }
            }
            reporter.flushRefLines()
        }
    }

    public func checkout(ref: String) async throws {
        try await withRepository { repo in
            var object: OpaquePointer?
            try check(git_revparse_single(&object, repo, ref))
            defer { git_object_free(object) }

            var opts = git_checkout_options()
            try check(git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
            opts.checkout_strategy = UInt32(GIT_CHECKOUT_SAFE.rawValue)

            try check(git_checkout_tree(repo, object, &opts))

            // After updating the working tree, point HEAD at the ref so
            // subsequent commits land on the right branch. For branch
            // names, use the full refname; for tags / SHAs, set head detached.
            var resolved: OpaquePointer?
            let lookupRC = git_branch_lookup(&resolved, repo, ref, GIT_BRANCH_LOCAL)
            if lookupRC == 0 {
                defer { git_reference_free(resolved) }
                if let name = git_reference_name(resolved) {
                    try check(git_repository_set_head(repo, name))
                    return
                }
            }
            // Not a local branch — detach HEAD onto the resolved object.
            let oid = git_object_id(object)
            try check(git_repository_set_head_detached(repo, oid))
        }
    }

    public func push(remote: String, refspec: String, setUpstream: Bool) async throws {
        try await withRepository { repo in
            var remoteHandle: OpaquePointer?
            try check(git_remote_lookup(&remoteHandle, repo, remote))
            defer { git_remote_free(remoteHandle) }

            let remoteURL = git_remote_url(remoteHandle).map { String(cString: $0) }
            var reporter = ProgressReporter(
                headerURL: remoteURL, direction: .push)
            reporter.suppressTransferProgress =
                ProgressReporter.isLocalURL(remoteURL)

            try refspec.withCString { cstr in
                var copy: UnsafeMutablePointer<CChar>? = strdup(cstr)
                defer { free(copy) }
                try withUnsafeMutablePointer(to: &copy) { copyPtr in
                    var arr = git_strarray(strings: copyPtr, count: 1)
                    var opts = git_push_options()
                    try check(git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION)))
                    try withCallbacksPayload(
                        credentials: credentials, reporter: reporter,
                        { credCB, sidebandCB, _, _, pushRefCB, packCB, pushTransferCB, payload in
                            opts.callbacks.credentials = credCB
                            opts.callbacks.sideband_progress = sidebandCB
                            opts.callbacks.push_update_reference = pushRefCB
                            opts.callbacks.pack_progress = packCB
                            opts.callbacks.push_transfer_progress = pushTransferCB
                            opts.callbacks.payload = payload
                            try check(git_remote_push(remoteHandle, &arr, &opts))
                        },
                        outReporter: { reporter = $0 })
                }
            }

            reporter.flushRefLines()

            // libgit2 doesn't have a one-shot "push -u": after a successful
            // push, write the upstream config ourselves to mirror the CLI's
            // `--set-upstream` semantics.
            if setUpstream {
                try setUpstreamForRefspec(repo: repo, remote: remote, refspec: refspec)
            }
        }
    }

    public func addRemote(name: String, url: URL) async throws {
        try await withRepository { repo in
            var remote: OpaquePointer?
            try check(git_remote_create(&remote, repo, name, url.absoluteString))
            git_remote_free(remote)
        }
    }

    /// Stage every tracked file that has working-tree changes —
    /// the libgit2 equivalent of `git add -u`. Untracked files are
    /// left alone. Called by `commit -a` / `commit --all` to keep
    /// `commit` itself confined to "record the index", with the
    /// staging step explicit and opt-in.
    public func stageTrackedChanges() async throws {
        try await withRepository { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            // `update_all` re-reads only paths that are already in
            // the index — exactly the `add -u` semantics we want.
            try check(git_index_update_all(index, nil, nil, nil))
            try check(git_index_write(index))
        }
    }

    public func add(paths: [String]) async throws {
        try await withRepository { repo in
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }

            if paths.isEmpty {
                try check(git_index_add_all(index, nil, 0, nil, nil))
            } else {
                // Use `git_index_add_bypath` per path rather than
                // `git_index_add_all` with a pathspec — `add_all`
                // ignores the pathspec for new files and stages
                // every untracked entry, so `git add sub/file.txt`
                // ended up staging everything below the worktree
                // root. `add_bypath` stages exactly the named blob.
                for path in paths {
                    try path.withCString { cstr in
                        try check(git_index_add_bypath(index, cstr))
                    }
                }
            }
            try check(git_index_write(index))
        }
    }

    @discardableResult
    public func commit(message: String, author: GitSignature?, allowEmpty: Bool) async throws -> String {
        try await commitDetailed(message: message, author: author, allowEmpty: allowEmpty).sha
    }

    /// Like ``commit(message:author:allowEmpty:)`` but returns the
    /// `[branch sha]`-style details the CLI uses to mirror `git commit`'s
    /// summary line. Throws ``Libgit2Error`` with a `nothingToCommit`
    /// flavour when the index matches HEAD and `allowEmpty == false`.
    public func commitDetailed(
        message: String,
        author: GitSignature?,
        allowEmpty: Bool
    ) async throws -> Libgit2CommitDetails {
        try await withRepository { repo in
            // Commit exactly what's staged in the index — DO NOT
            // implicitly stage working-tree changes first. The
            // previous behaviour called `git_index_add_all` here so
            // `git commit -m "x"` doubled as `git commit -a`, which
            // meant `git add sub/file.txt && git commit` ended up
            // committing every untracked file in the worktree
            // instead of just the named path. Callers that want
            // `commit -a` semantics should do their own explicit
            // `add(paths: [])` before calling this.
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }

            // 2. Resolve parent commit (if any). Unborn HEAD = first commit.
            var parentOID = git_oid()
            var parent: OpaquePointer?
            var hasParent = false
            var head: OpaquePointer?
            let headRC = git_repository_head(&head, repo)
            if headRC == 0 {
                defer { git_reference_free(head) }
                if let target = git_reference_target(head) {
                    parentOID = target.pointee
                    try check(git_commit_lookup(&parent, repo, &parentOID))
                    hasParent = true
                }
            } else if headRC != GIT_EUNBORNBRANCH.rawValue && headRC != GIT_ENOTFOUND.rawValue {
                try check(headRC)
            }
            defer { if hasParent { git_commit_free(parent) } }

            // 3. Build a tree from the index.
            var treeOID = git_oid()
            try check(git_index_write_tree(&treeOID, index))

            // 4. Refuse empty commits unless explicitly allowed. Compare
            //    the new tree's OID to the parent's tree OID.
            if !allowEmpty, hasParent {
                let parentTreeOID = git_commit_tree_id(parent)
                let same = withUnsafePointer(to: treeOID) { lhs -> Bool in
                    guard let parentTreeOID else { return false }
                    return git_oid_cmp(lhs, parentTreeOID) == 0
                }
                if same {
                    throw Libgit2Error(
                        code: -1, klass: 0,
                        message: "nothing to commit, working tree clean")
                }
            }

            var newTree: OpaquePointer?
            try check(git_tree_lookup(&newTree, repo, &treeOID))
            defer { git_tree_free(newTree) }

            // 5. Diff stats — compute BEFORE creating the commit so we
            //    can format the summary line. Diff against parent's tree
            //    if we have one, else against the empty tree (root).
            var parentTree: OpaquePointer?
            if hasParent, let parentTreeOID = git_commit_tree_id(parent) {
                try check(git_tree_lookup(&parentTree, repo, parentTreeOID))
            }
            defer { if parentTree != nil { git_tree_free(parentTree) } }

            var diff: OpaquePointer?
            try check(git_diff_tree_to_tree(&diff, repo, parentTree, newTree, nil))
            defer { git_diff_free(diff) }

            var stats: OpaquePointer?
            try check(git_diff_get_stats(&stats, diff))
            defer { git_diff_stats_free(stats) }

            let filesChanged = Int(git_diff_stats_files_changed(stats))
            let insertions = Int(git_diff_stats_insertions(stats))
            let deletions = Int(git_diff_stats_deletions(stats))

            var added: [Libgit2CommitDetails.FileChange] = []
            var deleted: [Libgit2CommitDetails.FileChange] = []
            let numDeltas = Int(git_diff_num_deltas(diff))
            for i in 0..<numDeltas {
                guard let delta = git_diff_get_delta(diff, i) else { continue }
                let status = delta.pointee.status
                if status == GIT_DELTA_ADDED {
                    let p = String(cString: delta.pointee.new_file.path)
                    added.append(.init(path: p, mode: UInt32(delta.pointee.new_file.mode)))
                } else if status == GIT_DELTA_DELETED {
                    let p = String(cString: delta.pointee.old_file.path)
                    deleted.append(.init(path: p, mode: UInt32(delta.pointee.old_file.mode)))
                }
            }

            // 6. Resolve author + committer signatures separately —
            //    real git keeps them distinct so CI replay scenarios
            //    (different GIT_AUTHOR_* and GIT_COMMITTER_*) work.
            //    `SignatureResolver` honours the env-var precedence
            //    chain real git documents in `git-commit-tree(1)`.
            let authorSig = try SignatureResolver.resolve(
                role: .author, override: author, repo: repo)
            defer { git_signature_free(authorSig) }
            let committerSig = try SignatureResolver.resolve(
                role: .committer, override: nil, repo: repo)
            defer { git_signature_free(committerSig) }

            // 7. Create the commit, updating HEAD in one shot.
            var commitOID = git_oid()
            var parentArray: [OpaquePointer?] = hasParent ? [parent] : []
            _ = try parentArray.withUnsafeMutableBufferPointer { parents in
                try message.withCString { msg in
                    try check(git_commit_create(
                        &commitOID,
                        repo,
                        "HEAD",
                        authorSig,
                        committerSig,
                        nil,        // message_encoding (UTF-8 default)
                        msg,
                        newTree,
                        parents.count,
                        parents.baseAddress))
                }
            }

            // 8. Resolve current branch shorthand for the [branch sha] line.
            var branchName: String? = nil
            var head2: OpaquePointer?
            if git_repository_head(&head2, repo) == 0 {
                defer { git_reference_free(head2) }
                if let cstr = git_reference_shorthand(head2) {
                    let s = String(cString: cstr)
                    if s != "HEAD" { branchName = s }
                }
            }

            let sha = formatOID(&commitOID)
            return Libgit2CommitDetails(
                sha: sha,
                shortSHA: String(sha.prefix(7)),
                branchName: branchName,
                isRoot: !hasParent,
                filesChanged: filesChanged,
                insertions: insertions,
                deletions: deletions,
                addedFiles: added,
                deletedFiles: deleted)
        }
    }

    // MARK: Internals

    internal func withRepository<T>(_ body: (OpaquePointer?) throws -> T) async throws -> T {
        try await Shell.authorize(workingDirectory)
        // Tier-2 (#18): bridge sandbox env to libgit2's process-global
        // option block before opening the repo. The repo's frozen
        // config is then loaded against the sandbox's view, not the
        // host process env.
        return try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
            Libgit2.ensureInitialized()
            var repo: OpaquePointer?
            try check(git_repository_open_ext(&repo, workingDirectory.path, 0, nil))
            defer { git_repository_free(repo) }
            return try body(repo)
        }
    }

    /// `<src>:<dst>` form has both sides; bare ref like `main` means
    /// `refs/heads/main:refs/heads/main`. We only need the local side
    /// (the `src`) to set its upstream.
    private func setUpstreamForRefspec(repo: OpaquePointer?, remote: String, refspec: String) throws {
        let src: String
        if let colon = refspec.firstIndex(of: ":") {
            src = String(refspec[..<colon])
        } else {
            src = refspec
        }
        let stripped = src.hasPrefix("refs/heads/")
            ? String(src.dropFirst("refs/heads/".count))
            : src
        guard !stripped.isEmpty else { return }

        var branch: OpaquePointer?
        let lookupRC = git_branch_lookup(&branch, repo, stripped, GIT_BRANCH_LOCAL)
        guard lookupRC == 0 else { return }
        defer { git_reference_free(branch) }

        try check(git_branch_set_upstream(branch, "\(remote)/\(stripped)"))
    }

    /// Run `body` with an array of heap-allocated C strings (one per
    /// input). The `strdup`'d copies are freed when `body` returns.
    /// Used to build `git_strarray` payloads — libgit2 keeps the
    /// pointers alive only for the duration of the call.
    private func withCStringArray<T>(
        _ strings: [String],
        _ body: (inout [UnsafeMutablePointer<CChar>?]) throws -> T
    ) rethrows -> T {
        var copies: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { for c in copies { free(c) } }
        return try body(&copies)
    }

    internal func formatOID(_ oid: UnsafePointer<git_oid>) -> String {
        // 40 hex chars + NUL terminator.
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 41)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: 41)
        _ = git_oid_tostr(buf, 41, oid)
        return String(cString: buf)
    }

    private func defaultCloneDirectory(for url: URL) -> URL {
        let last = url.deletingPathExtension().lastPathComponent
        let folder = last.isEmpty ? "repo" : last
        return workingDirectory.appendingPathComponent(folder)
    }
}
