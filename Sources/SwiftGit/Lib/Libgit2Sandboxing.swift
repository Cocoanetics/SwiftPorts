import Foundation
import ShellKit
import CLibgit2Shim
import CGitKit
import GitKit

/// Bridges `Shell.current.environment.variables()` to libgit2's process-global option
/// block. Keeps libgit2's own `getenv` calls inside its C internals
/// from reading the host process env when a `Sandbox` is active.
///
/// libgit2's options (search paths, homedir, SSL cert locations) are
/// **process-global, not per-task**. Two tasks racing on the option
/// setter would corrupt each other's view. ``runIsolated(_:environment:diagnostics:body:)``
/// serialises the "set options + run body" sequence under one lock so each
/// run sees a consistent snapshot, and puts back the GLOBAL / XDG / SYSTEM
/// search paths and the homedir it found on entry before it releases the
/// lock. Between runs libgit2 therefore sees the process's own (or the
/// embedder's) options again, whichever run came last.
///
/// **What restoring doesn't cover.** A libgit2 or GitKit call made outside
/// a run while one is in progress, on another thread, sees that run's
/// options (and may read them while they are being rewritten). With
/// SwiftGit or GitLFSKit linked, an embedder routes every libgit2 / GitKit
/// call through an operation (`GitClient`, `GitLFSKit`'s operation entry)
/// so it takes the same lock.
///
/// **Mappings applied.** `HOME` and `XDG_CONFIG_HOME` are *always*
/// applied, sandbox or not — the shell's value takes precedence when
/// supplied; otherwise a sandbox falls back to its own home (so isolation
/// is the default for `Sandbox.rooted(at:)`, whose default `environment()`
/// doesn't include `HOME`) and no sandbox to the process's.
///
/// | Source | Applied as |
/// |---|---|
/// | `env["HOME"]`, else the sandbox's home / the process's | `SET_SEARCH_PATH(GLOBAL, …)` + `SET_HOMEDIR(…)` |
/// | `env["XDG_CONFIG_HOME"]`, else `<home>/.config` | `SET_SEARCH_PATH(XDG, <that>/git)` |
/// | sandbox without ``GitSandboxPolicy/allowsHostSystemConfig``, or `env["GIT_CONFIG_NOSYSTEM"]` true | `SET_SEARCH_PATH(SYSTEM, "")` |
/// | `GIT_CONFIG_GLOBAL` set | `SET_SEARCH_PATH(GLOBAL, "")` and `(XDG, "")`; the named file is added once the config is open (``EnvironmentConfig``) |
/// | `GIT_CONFIG_SYSTEM` set | `SET_SEARCH_PATH(SYSTEM, "")`; the named file is added once the config is open |
///
/// A search path holds directories, so a file of any name (`GIT_CONFIG_GLOBAL`,
/// `GIT_CONFIG_SYSTEM`) can't be reached through one: those levels are
/// switched off here and the file is force-added to the open config, along
/// with the `GIT_CONFIG_COUNT` entries, by `GitClient.installEnvironmentConfig`.
///
/// A sandbox does not read the host's system gitconfig (it can set
/// credential helpers and include paths outside the sandbox); an embedder
/// opts in with ``GitSandboxPolicy/allowsHostSystemConfig``.
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

    /// What the most recent application set.
    private struct AppliedSnapshot: Equatable {
        let home: String
        let xdg: String
        let noSystem: Bool
        let sandboxed: Bool
        let allowsHostSystem: Bool
        let hostSystemSearchPath: String?
        let environment: EnvironmentConfig
    }
    private let lock = NSLock()
    /// Where an opted-in sandbox looks for the system config; nil is
    /// libgit2's default. A seam for tests, which can't rely on the host's.
    /// It applies only inside a run: the SYSTEM path is put back on exit.
    var hostSystemSearchPath: String?
    private var lastApplied: AppliedSnapshot?
    /// What `GIT_CONFIG_GLOBAL` / `GIT_CONFIG_SYSTEM` / `GIT_CONFIG_COUNT`
    /// ask of the run in progress; read while ``runIsolated(_:environment:diagnostics:body:)``
    /// holds the lock. Back to `.none` once the run ends.
    private(set) var environment = EnvironmentConfig.none

    /// libgit2's options a run changes, as they stood before it.
    private struct HostOptions {
        let global: String
        let xdg: String
        let system: String
        let homedir: String
    }

    /// The home directory libgit2 is pointed at for `sandbox`: the shell's
    /// `HOME`, else the sandbox's own home, as `apply` sets it. Without a
    /// sandbox the shell's `HOME` is all there is, as git has one
    /// environment: an empty one is the root (`--global` is `/.gitconfig`),
    /// a missing one no home (``homeIsUnset(for:)``), never the host's.
    func home(for sandbox: Sandbox?) -> String {
        let variables = Shell.current.environment.variables
        if let home = Self.nonEmpty(variables["HOME"]) { return home }
        guard let sandbox else { return "" }
        return sandbox.homeDirectory.path
    }

    /// Whether git has no home for `sandbox`: no sandbox, and a shell
    /// that doesn't set `HOME`.
    func homeIsUnset(for sandbox: Sandbox?) -> Bool {
        sandbox == nil && Shell.current.environment.variables["HOME"] == nil
    }

    /// The XDG config directory git uses for `sandbox`: the shell's
    /// `XDG_CONFIG_HOME` (as `apply` sets it), else `<home>/.config`.
    func xdgConfigHome(for sandbox: Sandbox?) -> String {
        if let xdg = Self.nonEmpty(Shell.current.environment.variables["XDG_CONFIG_HOME"]) { return xdg }
        return home(for: sandbox) + "/.config"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// An environment variable read as git reads a boolean one
    /// (`git_env_bool`): unset and empty are off, a boolean or an integer is
    /// itself, anything else stops the command (`fatal: bad boolean
    /// environment value`).
    static func boolean(_ value: String?, named name: String) throws -> Bool {
        guard let value, !value.isEmpty else { return false }
        var parsed: CInt = 0
        if value.withCString({ git_config_parse_bool(&parsed, $0) }) == 0 { return parsed != 0 }
        if let number = Int(value) { return number != 0 }
        throw GitDiagnosticError(
            lines: ["fatal: bad boolean environment value '\(value)' for '\(name)'"], exitCode: 128)
    }

    /// The directory of the global `.gitconfig` libgit2 currently looks
    /// in: the shell's home as the run in progress applied it.
    /// Read inside ``runIsolated(_:environment:diagnostics:body:)``; outside one it is
    /// the process's home.
    var globalHome: String { lastApplied?.home ?? NSHomeDirectory() }

    /// Apply the shell's env→option mapping and run `body` while
    /// the lock is held. When `body` returns or throws, libgit2's options
    /// are put back as they were on entry, and then the lock is released. The
    /// caller's body should perform the libgit2 repo open inside it
    /// so the per-repo config is loaded against this sandbox's
    /// settings.
    ///
    /// `environment` is what `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM` and
    /// `GIT_CONFIG_COUNT` ask for (see `GitClient.environmentConfig()`);
    /// it stays readable as ``environment`` for as long as `body` runs, for
    /// whoever opens a config in it.
    ///
    /// Sync because libgit2's option SETs and the immediate repo
    /// open are sync C calls; awaiting an actor here would force
    /// every body closure to be `@Sendable`-compatible, which the
    /// `(OpaquePointer?) throws -> T` shapes used throughout SwiftGit
    /// are not. The lock is held for the duration of `body`, so
    /// concurrent SwiftGit operations on different sandboxes
    /// serialise — which is the correct behavior given that
    /// libgit2's option block is process-global.
    ///
    /// The configs opened in `body` report their nonfatal diagnostics to
    /// `diagnostics` (``record(_:)``); without a sink they are dropped.
    func runIsolated<T>(_ sandbox: Sandbox?,
                        environment: EnvironmentConfig = .none,
                        diagnostics: ConfigDiagnosticSink? = nil,
                        body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let entry = try captureHostOptions()
        // Declared after the unlock, so it runs first, under the lock.
        defer {
            restore(entry)
            self.environment = .none
            diagnosticSink = nil
            lastApplied = nil
        }
        try apply(sandbox, environment: environment)
        diagnosticSink = diagnostics
        return try body()
    }

    /// Where the run in progress collects its configs' diagnostics.
    private var diagnosticSink: ConfigDiagnosticSink?

    /// Keeps `diagnostics`, which a config opened in the run in progress
    /// reported, for the run to print.
    func record(_ diagnostics: [ConfigDiagnostic]) {
        guard !diagnostics.isEmpty else { return }
        diagnosticSink?.record(diagnostics)
    }

    /// Runs `body` holding the lock ``runIsolated(_:environment:diagnostics:body:)``
    /// takes, without applying anything: for tests that set or read
    /// libgit2's options themselves.
    func withOptionsLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Apply the env→option mapping. It is applied every time, never
    /// skipped for being the same as last time: libgit2's options are
    /// process-global, and anything else that sets one (an embedder, a
    /// test) would otherwise leave this bridge believing its state still
    /// stood.
    ///
    /// `HOME` and `XDG_CONFIG_HOME` are always applied — the shell's value
    /// when present, a sandbox-derived (or the process's) fallback
    /// otherwise. This makes the env-isolation default-secure for
    /// `Sandbox.rooted(at:)`, whose default `environment()` doesn't
    /// include either key.
    private func apply(_ sandbox: Sandbox?, environment plan: EnvironmentConfig) throws {
        // Environment shadow now lives on `Shell`, not `Sandbox`.
        // The TaskLocal `Shell.current` is what callers bind alongside
        // their Sandbox; read variables through it.
        let env = Shell.current.environment.variables

        // Default-secure: when env doesn't supply HOME / XDG_CONFIG_HOME,
        // fall back to sandbox-derived paths so libgit2's GLOBAL / XDG
        // config search lands inside the sandbox rather than at the
        // host user's `~/.gitconfig`.
        let snapshot = AppliedSnapshot(
            home: home(for: sandbox),
            xdg: xdgConfigHome(for: sandbox),
            noSystem: (try? Self.boolean(env["GIT_CONFIG_NOSYSTEM"], named: "GIT_CONFIG_NOSYSTEM")) ?? false,
            sandboxed: sandbox != nil,
            allowsHostSystem: GitSandboxPolicy.allowsHostSystemConfig,
            hostSystemSearchPath: hostSystemSearchPath,
            environment: plan)

        // GLOBAL search + HOMEDIR — both pinned to the shell's view. With
        // GIT_CONFIG_GLOBAL, git reads that file and neither home file.
        // An empty HOME is the root; a missing one leaves no home file.
        let globalNamed = snapshot.environment.globalOverride
        let noHome = homeIsUnset(for: sandbox)
        let home = snapshot.home.isEmpty ? "/" : snapshot.home
        try setSearchPath(level: GIT_CONFIG_LEVEL_GLOBAL.rawValue, path: globalNamed || noHome ? "" : home)
        try setHomedir(path: home)

        // XDG search: libgit2's path for this level is the `git` directory
        // inside `$XDG_CONFIG_HOME`, which holds the `config` file.
        let xdgOff = globalNamed || (noHome && Self.nonEmpty(env["XDG_CONFIG_HOME"]) == nil)
        try setSearchPath(level: GIT_CONFIG_LEVEL_XDG.rawValue,
                          path: xdgOff ? "" : snapshot.xdg + "/git")

        // GIT_CONFIG_NOSYSTEM, no opt-in to the host's (in a sandbox), or a
        // file GIT_CONFIG_SYSTEM names (added to the open config instead) →
        // disable system search.
        let hostSystemOff = snapshot.sandboxed && !snapshot.allowsHostSystem
        if snapshot.noSystem || hostSystemOff || snapshot.environment.systemOverride {
            try setSearchPath(level: GIT_CONFIG_LEVEL_SYSTEM.rawValue, path: "")
        } else if let path = snapshot.hostSystemSearchPath {
            try setSearchPath(level: GIT_CONFIG_LEVEL_SYSTEM.rawValue, path: path)
        } else {
            try resetSearchPath(level: GIT_CONFIG_LEVEL_SYSTEM.rawValue)
        }

        environment = plan
        lastApplied = snapshot
    }

    private func captureHostOptions() throws -> HostOptions {
        HostOptions(
            global: try Self.option("GET_SEARCH_PATH(GLOBAL)") {
                swiftports_libgit2_get_search_path(Int32(GIT_CONFIG_LEVEL_GLOBAL.rawValue), $0, $1)
            },
            xdg: try Self.option("GET_SEARCH_PATH(XDG)") {
                swiftports_libgit2_get_search_path(Int32(GIT_CONFIG_LEVEL_XDG.rawValue), $0, $1)
            },
            system: try Self.option("GET_SEARCH_PATH(SYSTEM)") {
                swiftports_libgit2_get_search_path(Int32(GIT_CONFIG_LEVEL_SYSTEM.rawValue), $0, $1)
            },
            homedir: try Self.option("GET_HOMEDIR") { swiftports_libgit2_get_homedir($0, $1) })
    }

    /// Puts `options` back. A level that can't be set falls back to
    /// libgit2's default; an empty homedir is libgit2's default too, never
    /// `""`.
    ///
    /// libgit2's setter splices the current value in for a `$PATH` in the
    /// new one, so a value holding a literal `$PATH` can't be set back as
    /// it reads. Such a value is libgit2's default (guessed from a `HOME`
    /// or `XDG_CONFIG_HOME` that contains it) and is restored by resetting
    /// to the default; one that isn't stays at the default.
    private func restore(_ options: HostOptions) {
        let levels = [(GIT_CONFIG_LEVEL_GLOBAL, options.global),
                      (GIT_CONFIG_LEVEL_XDG, options.xdg),
                      (GIT_CONFIG_LEVEL_SYSTEM, options.system)]
        for (level, path) in levels {
            let level = Int32(level.rawValue)
            let result = Self.isLiteral(path)
                ? path.withCString { swiftports_libgit2_set_search_path(level, $0) }
                : swiftports_libgit2_set_search_path(level, nil)
            if result != 0 {
                assertionFailure("libgit2 refused to restore search path level \(level)")
                _ = swiftports_libgit2_set_search_path(level, nil)
            }
        }
        let result = !options.homedir.isEmpty && Self.isLiteral(options.homedir)
            ? options.homedir.withCString { swiftports_libgit2_set_homedir($0) }
            : swiftports_libgit2_set_homedir(nil)
        assert(result == 0, "libgit2 refused to restore the homedir")
    }

    /// Whether libgit2's setter stores `value` as it is: it expands `$PATH`.
    private static func isLiteral(_ value: String) -> Bool {
        !value.contains("$PATH")
    }

    /// Reads one string option through `get`, growing the buffer while
    /// libgit2 reports it too short.
    private static func option(
        _ name: String, _ get: (UnsafeMutablePointer<CChar>, Int) -> Int32
    ) throws -> String {
        var size = 4_096
        while true {
            var buffer = [CChar](repeating: 0, count: size)
            let result = buffer.withUnsafeMutableBufferPointer { get($0.baseAddress!, $0.count) }
            if result == 0 {
                return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
            guard result == GIT_EBUFS.rawValue, size < 1 << 20 else {
                throw Libgit2SandboxingError.optionGetFailed(option: name, rc: result)
            }
            size *= 4
        }
    }

    // MARK: - Thin wrappers around CLibgit2Shim

    private func setSearchPath(level: Int32, path: String) throws {
        let result = path.withCString { swiftports_libgit2_set_search_path(level, $0) }
        if result != 0 {
            throw Libgit2SandboxingError.optionSetFailed(
                option: "SET_SEARCH_PATH(\(level))", rc: result)
        }
    }

    private func resetSearchPath(level: Int32) throws {
        let result = swiftports_libgit2_set_search_path(level, nil)
        if result != 0 {
            throw Libgit2SandboxingError.optionSetFailed(
                option: "SET_SEARCH_PATH(\(level)) reset", rc: result)
        }
    }

    private func setHomedir(path: String) throws {
        let result = path.withCString { swiftports_libgit2_set_homedir($0) }
        if result != 0 {
            throw Libgit2SandboxingError.optionSetFailed(
                option: "SET_HOMEDIR", rc: result)
        }
    }

}

/// Errors thrown by the libgit2 sandboxing actor when an option SET (or
/// the GET of the options a run puts back) returns non-zero. In practice
/// these don't fire — libgit2's option setters succeed for any valid input.
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

    public static func optionGetFailed(option: String, rc: Int32) -> Self {
        Self(option: option, rc: rc)
    }

    public var description: String {
        "libgit2 option failed: \(option) returned \(rc)"
    }
}
