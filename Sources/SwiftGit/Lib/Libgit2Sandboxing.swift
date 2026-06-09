import Foundation
import ShellKit
import CLibgit2Shim
import libgit2

/// Bridges `Shell.current.environment.variables()` to libgit2's process-global option
/// block. Keeps libgit2's own `getenv` calls inside its C internals
/// from reading the host process env when a `Sandbox` is active.
///
/// libgit2's options (search paths, homedir, SSL cert locations) are
/// **process-global, not per-task**. Two tasks racing on the option
/// setter would corrupt each other's view. This actor serialises the
/// "set options + open repo" sequence so each repo sees a consistent
/// snapshot. Once libgit2's per-repo config has loaded into the
/// `git_repository*` handle, the actor releases — subsequent libgit2
/// calls on that repo read its frozen config, not the option block.
///
/// **Mappings applied** when a `Sandbox` is active. `HOME` and
/// `XDG_CONFIG_HOME` are *always* applied — the env value takes
/// precedence when supplied, otherwise we fall back to
/// sandbox-derived paths so isolation is the default for
/// `Sandbox.rooted(at:)` (whose default `environment()` doesn't
/// include `HOME`).
///
/// | Source | Applied as |
/// |---|---|
/// | `env["HOME"]`, else `sandbox.homeDirectory` | `SET_SEARCH_PATH(GLOBAL, …)` + `SET_HOMEDIR(…)` |
/// | `env["XDG_CONFIG_HOME"]`, else `<sandbox.homeDirectory>/.config` | `SET_SEARCH_PATH(XDG, …)` |
/// | `env["GIT_CONFIG_NOSYSTEM"] == "1"` | `SET_SEARCH_PATH(SYSTEM, "")` (only when set) |
///
/// Anything else stays embedder-controlled. Notably proxy env
/// continues to drive libgit2's HTTP transport, and SSL cert
/// locations stay at libgit2's defaults — `GIT_OPT_SET_SSL_CERT_LOCATIONS`
/// has no documented reset path in libgit2's API
/// (`(NULL, NULL)` returns an error; there's no `GET_SSL_CERT_LOCATIONS`),
/// so honest cross-sandbox transitions aren't possible. Embedders
/// that need per-sandbox SSL roots should set them explicitly via
/// libgit2 and accept process-lifetime stickiness.
///
/// **Honest scope.** This bridge closes the env-isolation gap for
/// libgit2's config-search and homedir-derived lookups. It does NOT
/// scrub the residual `GIT_*` env vars libgit2 reads via `getenv`
/// without an option counterpart (`GIT_DIR`, `GIT_OBJECT_DIRECTORY`,
/// `GIT_SSH`, etc.) — those are typically not set in iOS / app-sandbox
/// environments, and CLI / SwiftBash embedders that need full
/// isolation can `unsetenv` themselves at process startup. Process
/// proxy env (`http_proxy` etc.) is left intact so embedders retain
/// the ability to pin or disable proxies on a per-call basis via
/// `git_fetch_options.proxy_opts`.
internal final class Libgit2Sandboxing: @unchecked Sendable {
    static let shared = Libgit2Sandboxing()

    /// Snapshot of the most recent application so we can no-op when
    /// the same sandbox is re-applied.
    private struct AppliedSnapshot: Equatable {
        let home: String
        let xdg: String
        let noSystem: Bool
    }
    private let lock = NSLock()
    private var lastApplied: AppliedSnapshot?

    /// Apply the sandbox's env→option mapping and run `body` while
    /// the lock is held. Releases the lock when `body` returns. The
    /// caller's body should perform the libgit2 repo open inside it
    /// so the per-repo config is loaded against this sandbox's
    /// settings.
    ///
    /// Sync because libgit2's option SETs and the immediate repo
    /// open are sync C calls; awaiting an actor here would force
    /// every body closure to be `@Sendable`-compatible, which the
    /// `(OpaquePointer?) throws -> T` shapes used throughout SwiftGit
    /// are not. The lock is held for the duration of `body`, so
    /// concurrent SwiftGit operations on different sandboxes
    /// serialise — which is the correct behavior given that
    /// libgit2's option block is process-global.
    func runIsolated<T>(_ sandbox: Sandbox?,
                        body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try apply(sandbox)
        return try body()
    }

    /// Apply the sandbox's env→option mapping. Idempotent: re-applying
    /// the same effective mapping is a no-op.
    ///
    /// `HOME` and `XDG_CONFIG_HOME` are always applied — env value
    /// when present, sandbox-derived fallback otherwise. This makes
    /// the env-isolation default-secure for `Sandbox.rooted(at:)`,
    /// whose default `environment()` doesn't include either key.
    private func apply(_ sandbox: Sandbox?) throws {
        guard let sandbox else {
            // Return to libgit2's defaults so non-sandboxed code in
            // the same process keeps working.
            try resetToDefaults()
            lastApplied = nil
            return
        }

        // Environment shadow now lives on `Shell`, not `Sandbox`.
        // The TaskLocal `Shell.current` is what callers bind alongside
        // their Sandbox; read variables through it.
        let env = Shell.current.environment.variables
        let envHome = env["HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let envXDG = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }

        // Default-secure: when env doesn't supply HOME / XDG_CONFIG_HOME,
        // fall back to sandbox-derived paths so libgit2's GLOBAL / XDG
        // config search lands inside the sandbox rather than at the
        // host user's `~/.gitconfig`.
        let snapshot = AppliedSnapshot(
            home: envHome ?? sandbox.homeDirectory.path,
            xdg: envXDG ?? sandbox.homeDirectory
                .appendingPathComponent(".config", isDirectory: true).path,
            noSystem: env["GIT_CONFIG_NOSYSTEM"] == "1")

        if snapshot == lastApplied { return }

        // GLOBAL search + HOMEDIR — both pinned to the sandbox view.
        try setSearchPath(level: GIT_CONFIG_LEVEL_GLOBAL.rawValue, path: snapshot.home)
        try setHomedir(path: snapshot.home)

        // XDG search.
        try setSearchPath(level: GIT_CONFIG_LEVEL_XDG.rawValue, path: snapshot.xdg)

        // GIT_CONFIG_NOSYSTEM=1 → disable system search.
        if snapshot.noSystem {
            try setSearchPath(level: GIT_CONFIG_LEVEL_SYSTEM.rawValue, path: "")
        } else {
            try resetSearchPath(level: GIT_CONFIG_LEVEL_SYSTEM.rawValue)
        }

        lastApplied = snapshot
    }

    private func resetToDefaults() throws {
        try resetSearchPath(level: GIT_CONFIG_LEVEL_GLOBAL.rawValue)
        try resetSearchPath(level: GIT_CONFIG_LEVEL_XDG.rawValue)
        try resetSearchPath(level: GIT_CONFIG_LEVEL_SYSTEM.rawValue)
        try resetHomedir()
    }

    // MARK: - Thin wrappers around CLibgit2Shim

    private func setSearchPath(level: Int32, path: String) throws {
        let rc = path.withCString { swiftports_libgit2_set_search_path(level, $0) }
        if rc != 0 {
            throw Libgit2SandboxingError.optionSetFailed(
                option: "SET_SEARCH_PATH(\(level))", rc: rc)
        }
    }

    private func resetSearchPath(level: Int32) throws {
        let rc = swiftports_libgit2_set_search_path(level, nil)
        if rc != 0 {
            throw Libgit2SandboxingError.optionSetFailed(
                option: "SET_SEARCH_PATH(\(level)) reset", rc: rc)
        }
    }

    private func setHomedir(path: String) throws {
        let rc = path.withCString { swiftports_libgit2_set_homedir($0) }
        if rc != 0 {
            throw Libgit2SandboxingError.optionSetFailed(
                option: "SET_HOMEDIR", rc: rc)
        }
    }

    private func resetHomedir() throws {
        let rc = swiftports_libgit2_set_homedir(nil)
        if rc != 0 {
            throw Libgit2SandboxingError.optionSetFailed(
                option: "SET_HOMEDIR reset", rc: rc)
        }
    }

}

/// Errors thrown by the libgit2 sandboxing actor when an option SET
/// returns non-zero. In practice these don't fire — libgit2's option
/// setters succeed for any valid input.
public struct Libgit2SandboxingError: Error, Sendable, CustomStringConvertible {
    public let option: String
    public let rc: Int32

    public init(option: String, rc: Int32) {
        self.option = option
        self.rc = rc
    }

    public static func optionSetFailed(option: String, rc: Int32) -> Self {
        Self(option: option, rc: rc)
    }

    public var description: String {
        "libgit2 option SET failed: \(option) returned \(rc)"
    }
}
