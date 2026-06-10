import Foundation
import ForgeKit
import ShellKit
@_exported import GitKit

/// In-process libgit2-backed implementation of
/// ``ForgeKit/GitClient`` (the protocol). The simple name `GitClient`
/// is reserved here in `SwiftGit` for the canonical concrete client;
/// the `ForgeKit` protocol is referred to in fully-qualified form
/// below to disambiguate.
///
/// `GitClient` is the **sandbox-aware face** over the pure
/// `GitKit.Repository` SDK: every operation authorizes the paths it
/// will touch through ``ShellKit/Shell/authorize(_:)``, bridges the
/// sandbox environment to libgit2's process-global options
/// (`Libgit2Sandboxing`), opens the repository, and delegates to the
/// corresponding `Repository` method. The core SDK itself performs no
/// gating and reads no ambient shell state — hosts that don't need a
/// sandbox use `GitKit` directly.
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
        try await withRepository { try $0.remoteURL(named: name) }
    }

    public func currentBranch() async throws -> String? {
        try await withRepository { try $0.currentBranch() }
    }

    public func upstreamBranch(of localBranch: String) async throws -> String? {
        try await withRepository { try $0.upstreamBranch(of: localBranch) }
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
        let progress = shellProgressSink()
        // Tier-2 (#18): apply env→option bridge before clone so the
        // freshly-init'd repo's config is loaded against the sandbox.
        try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
            _ = try Repository.clone(
                from: url, to: destURL,
                credentials: credentials, progress: progress)
        }
    }

    public func fetch(remote: String, refspec: String) async throws {
        let progress = shellProgressSink()
        try await withRepository {
            try $0.fetch(remote: remote, refspec: refspec,
                         credentials: credentials, progress: progress)
        }
    }

    public func checkout(ref: String) async throws {
        try await withRepository { try $0.checkout(ref: ref) }
    }

    public func push(remote: String, refspec: String, setUpstream: Bool) async throws {
        let progress = shellProgressSink()
        try await withRepository {
            try $0.push(remote: remote, refspec: refspec, setUpstream: setUpstream,
                        credentials: credentials, progress: progress)
        }
    }

    public func addRemote(name: String, url: URL) async throws {
        try await withRepository { try $0.addRemote(name: name, url: url) }
    }

    /// Stage every tracked file that has working-tree changes —
    /// the libgit2 equivalent of `git add -u`. Untracked files are
    /// left alone. Called by `commit -a` / `commit --all` to keep
    /// `commit` itself confined to "record the index", with the
    /// staging step explicit and opt-in.
    public func stageTrackedChanges() async throws {
        try await withRepository { try $0.stageTrackedChanges() }
    }

    public func add(paths: [String]) async throws {
        try await withRepository { try $0.add(paths: paths) }
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
        let env = shellEnvironment()
        return try await withRepository {
            try $0.commitDetailed(
                message: message,
                author: author.core,
                allowEmpty: allowEmpty,
                env: env)
        }
    }

    // MARK: Internals — the sandbox seam

    /// Authorize `workingDirectory`, bridge the sandbox environment to
    /// libgit2's process-global options, open the repository, and run
    /// `body` on it. Every `GitClient` operation funnels through here, so
    /// the per-op sandbox check and config isolation happen in exactly one
    /// place — and the `GitKit` SDK below stays shell-free.
    internal func withRepository<T>(_ body: (Repository) throws -> T) async throws -> T {
        try await Shell.authorize(workingDirectory)
        // Tier-2 (#18): bridge sandbox env to libgit2's process-global
        // option block before opening the repo. The repo's frozen
        // config is then loaded against the sandbox's view, not the
        // host process env.
        return try Libgit2Sandboxing.shared.runIsolated(Shell.current.sandbox) {
            let repo = try Repository.open(at: workingDirectory)
            return try body(repo)
        }
    }

    /// The shell's view of the environment, for the real-git identity
    /// precedence chain (`GIT_AUTHOR_*` / `GIT_COMMITTER_*`).
    internal func shellEnvironment() -> [String: String] {
        Shell.current.environment.variables
    }

    /// Progress sink writing through the current shell's stderr. Captured
    /// eagerly (the task-local `Shell.current`) so callbacks firing on
    /// libgit2's threads still hit the right shell.
    internal func shellProgressSink() -> @Sendable (String) -> Void {
        let stderr = Shell.current.stderr
        return { stderr.write(Data($0.utf8)) }
    }

    private func defaultCloneDirectory(for url: URL) -> URL {
        let last = url.deletingPathExtension().lastPathComponent
        let folder = last.isEmpty ? "repo" : last
        return workingDirectory.appendingPathComponent(folder)
    }
}

extension Optional where Wrapped == GitSignature {
    /// Map ForgeKit's signature type onto the core SDK's at the wrapper
    /// boundary — the two are structurally identical.
    var core: Signature? {
        map { Signature(name: $0.name, email: $0.email) }
    }
}
