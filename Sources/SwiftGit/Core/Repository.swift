import Foundation
import CGitKit

/// An open libgit2 repository — the handle every operation in this module
/// is a method on, mirroring libgit2's own `git_repository *` model.
///
/// `Repository` is the pure-SDK face: it performs **no** access gating and
/// reads **no** ambient environment. Open it, call operations, let ARC free
/// it. Hosts that gate file access (sandboxes, shell embedders) authorize
/// paths *before* opening and wrap calls in whatever isolation they need —
/// see SwiftPorts' `GitClient`, which layers exactly that on top.
///
/// Not thread-safe (libgit2 repositories aren't): confine an instance to
/// one task/thread at a time.
public final class Repository {

    /// The raw `git_repository *`. Public as a deliberate escape hatch so
    /// embedders can reach libgit2 API this wrapper doesn't surface yet.
    public let pointer: OpaquePointer

    /// Internal alias letting operation bodies keep the conventional
    /// libgit2 parameter name (`repo`) after their move from closure-based
    /// call sites.
    var repo: OpaquePointer { pointer }

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        git_repository_free(pointer)
    }

    /// The repository's working-directory URL, `nil` for bare repos.
    public var workdirURL: URL? {
        guard let cstr = git_repository_workdir(pointer) else { return nil }
        return URL(fileURLWithPath: String(cString: cstr), isDirectory: true)
    }

    /// `workdirURL` or a thrown error — for worktree operations that make
    /// no sense on a bare repository.
    func requireWorkdir() throws -> URL {
        guard let url = workdirURL else {
            throw Libgit2Error(code: -1, klass: 0,
                message: "operation requires a working directory (bare repository)")
        }
        return url
    }

    // MARK: Lifecycle

    /// Open the repository at (or above) `url`, exactly like
    /// `git_repository_open_ext` with default flags.
    public static func open(at url: URL) throws -> Repository {
        Libgit2.ensureInitialized()
        var repo: OpaquePointer?
        try check(git_repository_open_ext(&repo, url.path, 0, nil))
        guard let repo else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_repository_open_ext returned no repository")
        }
        return Repository(pointer: repo)
    }

    /// Initialise a brand-new repository at `url` (creating the directory
    /// if needed) and return it open. Mirrors `git init` semantics.
    ///
    /// - Parameters:
    ///   - bare: Create a bare repo (`init --bare`) — no working tree.
    ///   - initialBranch: Override the default branch name (real git uses
    ///     `init.defaultBranch`, falling back to `master`).
    ///   - reinit: If `true`, succeed silently when the directory is
    ///     already a repo. If `false` (the default), libgit2 errors.
    @discardableResult
    public static func initialize(
        at url: URL,
        bare: Bool = false,
        initialBranch: String? = nil,
        reinit: Bool = false
    ) throws -> Repository {
        Libgit2.ensureInitialized()
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)

        var opts = git_repository_init_options()
        try check(git_repository_init_init_options(
            &opts, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)))

        var flags: UInt32 = UInt32(GIT_REPOSITORY_INIT_MKDIR.rawValue)
            | UInt32(GIT_REPOSITORY_INIT_MKPATH.rawValue)
        if bare { flags |= UInt32(GIT_REPOSITORY_INIT_BARE.rawValue) }
        if !reinit { flags |= UInt32(GIT_REPOSITORY_INIT_NO_REINIT.rawValue) }
        opts.flags = flags

        // libgit2 holds a non-owning pointer into `initial_head`; keep
        // the C string alive across the call by going through withCString.
        var repo: OpaquePointer?
        if let branch = initialBranch {
            try branch.withCString { ptr in
                opts.initial_head = ptr
                try check(git_repository_init_ext(&repo, url.path, &opts))
            }
        } else {
            try check(git_repository_init_ext(&repo, url.path, &opts))
        }
        guard let repo else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_repository_init_ext returned no repository")
        }
        return Repository(pointer: repo)
    }

    /// Clone `url` into `directory` and return the new repository open.
    ///
    /// - Parameters:
    ///   - credentials: invoked by the transport on auth challenges.
    ///   - progress: sink for real-git-style transfer progress lines
    ///     (defaults to the process's stderr).
    @discardableResult
    public static func clone(
        from url: URL,
        to directory: URL,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws -> Repository {
        Libgit2.ensureInitialized()

        var opts = git_clone_options()
        try check(git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION)))

        var reporter = ProgressReporter(
            headerURL: url.absoluteString, direction: .fetch, output: progress)
        // Real git's local clone (file:// or bare path) skips the
        // `remote: …` / `Receiving objects: …` lines — match it.
        reporter.suppressTransferProgress =
            ProgressReporter.isLocalURL(url.absoluteString)

        var out: OpaquePointer?
        try withCallbacksPayload(
            credentials: credentials, reporter: reporter,
            { credCB, sidebandCB, transferCB, _, _, _, _, payload in
                opts.fetch_opts.callbacks.credentials = credCB
                opts.fetch_opts.callbacks.sideband_progress = sidebandCB
                opts.fetch_opts.callbacks.transfer_progress = transferCB
                opts.fetch_opts.callbacks.payload = payload

                try check(git_clone(&out, url.absoluteString, directory.path, &opts))
            },
            outReporter: { reporter = $0 })
        // No `From`/per-ref block on clone — real git just prints
        // `Cloning into '…'` (handled by the CLI subcommand) plus the
        // transfer progress lines we already emitted.
        guard let out else {
            throw Libgit2Error(code: -1, klass: 0, message: "git_clone returned no repository")
        }
        return Repository(pointer: out)
    }

    // MARK: Read

    public func remoteURL(named name: String) throws -> URL? {
        var remote: OpaquePointer?
        let rc = git_remote_lookup(&remote, repo, name)
        if rc == GIT_ENOTFOUND.rawValue { return nil }
        try check(rc)
        defer { git_remote_free(remote) }

        guard let cstr = git_remote_url(remote) else { return nil }
        let str = String(cString: cstr).trimmingCharacters(in: .whitespacesAndNewlines)
        return str.isEmpty ? nil : URL(string: str)
    }

    public func currentBranch() throws -> String? {
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

    public func upstreamBranch(of localBranch: String) throws -> String? {
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

    // MARK: Write

    public func fetch(
        remote: String,
        refspec: String,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws {
        var remoteHandle: OpaquePointer?
        try check(git_remote_lookup(&remoteHandle, repo, remote))
        defer { git_remote_free(remoteHandle) }

        // Pull the remote URL out of the handle for the `From <url>` header.
        let remoteURL = git_remote_url(remoteHandle).map { String(cString: $0) }
        var reporter = ProgressReporter(
            headerURL: remoteURL, direction: .fetch, output: progress)
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

    public func checkout(ref: String) throws {
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

    public func push(
        remote: String,
        refspec: String,
        setUpstream: Bool,
        credentials: CredentialProvider? = nil,
        progress: @escaping @Sendable (String) -> Void = GitProgress.standardError
    ) throws {
        var remoteHandle: OpaquePointer?
        try check(git_remote_lookup(&remoteHandle, repo, remote))
        defer { git_remote_free(remoteHandle) }

        let remoteURL = git_remote_url(remoteHandle).map { String(cString: $0) }
        var reporter = ProgressReporter(
            headerURL: remoteURL, direction: .push, output: progress)
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
            try setUpstreamForRefspec(remote: remote, refspec: refspec)
        }
    }

    public func addRemote(name: String, url: URL) throws {
        var remote: OpaquePointer?
        try check(git_remote_create(&remote, repo, name, url.absoluteString))
        git_remote_free(remote)
    }

    /// Stage every tracked file that has working-tree changes —
    /// the libgit2 equivalent of `git add -u`. Untracked files are
    /// left alone.
    public func stageTrackedChanges() throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }
        // `update_all` re-reads only paths that are already in
        // the index — exactly the `add -u` semantics we want.
        try check(git_index_update_all(index, nil, nil, nil))
        try check(git_index_write(index))
    }

    public func add(paths: [String]) throws {
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

    /// Commit exactly what's staged in the index onto HEAD and return the
    /// `[branch sha]`-style details the CLI uses to mirror `git commit`'s
    /// summary line. Throws ``Libgit2Error`` with a `nothing to commit`
    /// flavour when the index matches HEAD and `allowEmpty == false`.
    ///
    /// `env` feeds the real-git identity precedence chain
    /// (`GIT_AUTHOR_*` / `GIT_COMMITTER_*`); see ``SignatureResolver``.
    public func commitDetailed(
        message: String,
        author: Signature?,
        allowEmpty: Bool,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Libgit2CommitDetails {
        // Commit exactly what's staged in the index — DO NOT
        // implicitly stage working-tree changes first. Callers that want
        // `commit -a` semantics should do their own explicit
        // `add(paths: [])` before calling this.
        var index: OpaquePointer?
        try check(git_repository_index(&index, repo))
        defer { git_index_free(index) }

        // Resolve parent commit (if any). Unborn HEAD = first commit.
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

        // Build a tree from the index.
        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index))

        // Refuse empty commits unless explicitly allowed. Compare
        // the new tree's OID to the parent's tree OID.
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

        // Diff stats — compute BEFORE creating the commit so we
        // can format the summary line. Diff against parent's tree
        // if we have one, else against the empty tree (root).
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

        // Resolve author + committer signatures separately —
        // real git keeps them distinct so CI replay scenarios
        // (different GIT_AUTHOR_* and GIT_COMMITTER_*) work.
        // `SignatureResolver` honours the env-var precedence
        // chain real git documents in `git-commit-tree(1)`.
        let authorSig = try SignatureResolver.resolve(
            role: .author, override: author, repo: repo, env: env)
        defer { git_signature_free(authorSig) }
        let committerSig = try SignatureResolver.resolve(
            role: .committer, override: nil, repo: repo, env: env)
        defer { git_signature_free(committerSig) }

        // Create the commit, updating HEAD in one shot.
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

        // Resolve current branch shorthand for the [branch sha] line.
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

    // MARK: Internals

    /// `<src>:<dst>` form has both sides; bare ref like `main` means
    /// `refs/heads/main:refs/heads/main`. We only need the local side
    /// (the `src`) to set its upstream.
    private func setUpstreamForRefspec(remote: String, refspec: String) throws {
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
    func withCStringArray<T>(
        _ strings: [String],
        _ body: (inout [UnsafeMutablePointer<CChar>?]) throws -> T
    ) rethrows -> T {
        var copies: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { for c in copies { free(c) } }
        return try body(&copies)
    }

    func formatOID(_ oid: UnsafePointer<git_oid>) -> String {
        // 40 hex chars + NUL terminator.
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 41)
        defer { buf.deallocate() }
        buf.initialize(repeating: 0, count: 41)
        _ = git_oid_tostr(buf, 41, oid)
        return String(cString: buf)
    }
}
