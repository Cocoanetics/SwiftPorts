import Foundation
import ShellKit

/// Cross-platform persistent `SecretStore` backed by a single JSON file
/// with `0600` permissions inside a `0700` directory. This is the
/// fallback used when no OS keyring is reachable — headless Linux without
/// a Secret Service daemon, or Android without an embedder-injected
/// Keystore store.
///
/// It mirrors what `git credential-store` and upstream `glab` do by
/// default: the secret is protected by the (owner-only) directory + file
/// permissions plus the OS's per-user / per-app sandbox, not by
/// additional encryption.
///
/// On Android the natural `directory` is the app's private
/// `Context.filesDir`. Files there inherit OS at-rest encryption
/// (File-Based Encryption / Credential-Encrypted storage, keyed to the
/// user's lock credential and protected by the TEE) and per-UID
/// sandboxing — so an embedder should pass that directory. On a desktop
/// the file is plaintext-at-rest, which is why a native store (Keychain /
/// libsecret / Credential Manager) is always preferred when available;
/// see ``SystemSecretStore``.
///
/// When no directory is injected, the default location is resolved
/// against the **current** `Shell` environment on every operation, not
/// frozen at construction — so a long-lived embedder that swaps
/// `Shell.current` per command reads/writes the right config directory.
///
/// The on-disk layout is a nested map `service → account → secret`, so
/// neither identifier needs escaping:
///
///     {
///       "com.swiftgh.gh": { "github.com": "ghp_…" },
///       "com.swiftgl.glab": { "gitlab.com": "glpat_…" }
///     }
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    /// Explicit directory, or `nil` to resolve the default location
    /// against the current shell environment on each operation.
    private let injectedDirectory: URL?

    // Guards read-modify-write against concurrent in-process access.
    // `NSLock.withLock` keeps the package OS floor low (same rationale
    // as `InMemorySecretStore`). Cross-process races aren't guarded —
    // matching `git credential-store`.
    private let lock = NSLock()

    /// - Parameter directory: the directory that holds `secrets.json`.
    ///   `nil` (the default) resolves
    ///   `<XDG_CONFIG_HOME | $HOME/.config>/swiftports` per-operation.
    ///   Tests inject a temp dir; Android embedders pass `filesDir`.
    public init(directory: URL? = nil) {
        self.injectedDirectory = directory
    }

    /// The backing file, `<directory>/secrets.json`. With no injected
    /// directory this re-resolves against the current `Shell` env on each
    /// access (see the type doc).
    public var fileURL: URL {
        (injectedDirectory ?? Self.defaultDirectory())
            .appendingPathComponent("secrets.json", isDirectory: false)
    }

    public func get(service: String, account: String) async throws -> String? {
        lock.withLock { load(at: fileURL)[service]?[account] }
    }

    public func set(service: String, account: String, secret: String) async throws {
        try lock.withLock {
            let url = fileURL                       // one resolution per op
            var table = load(at: url)
            table[service, default: [:]][account] = secret
            try save(table, to: url)
        }
    }

    public func delete(service: String, account: String) async throws {
        try lock.withLock {
            let url = fileURL
            var table = load(at: url)
            guard table[service]?[account] != nil else { return }  // no-op if absent
            table[service]?[account] = nil
            if table[service]?.isEmpty == true { table[service] = nil }
            try save(table, to: url)
        }
    }

    // MARK: - File I/O (callers must hold `lock`)

    /// Decode the on-disk table. A missing *or corrupt* file is treated
    /// as empty so a single bad write can't permanently wedge the store.
    private func load(at url: URL) -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    private func save(_ table: [String: [String: String]], to url: URL) throws {
        try ensureDirectory(of: url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(table)
        try data.write(to: url, options: .atomic)
        #if !os(Windows)
        // Restrict to owner-only. NOT best-effort: a filesystem/mount
        // that can't honor 0600 must surface as a failed write rather
        // than a silent success that leaves the token readable. The
        // enclosing 0700 directory is the primary boundary; this is
        // defense in depth. (Windows uses ACLs under the user profile,
        // not POSIX mode bits, so it's skipped there.)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw SecretStoreError.backendError(
                status: 0,
                message: "could not restrict \(url.lastPathComponent) to 0600: "
                    + error.localizedDescription)
        }
        #endif
    }

    private func ensureDirectory(of url: URL) throws {
        let dir = url.deletingLastPathComponent()
        #if os(Windows)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        #endif
    }

    /// `<XDG_CONFIG_HOME | $HOME/.config>/swiftports`, resolved through
    /// `Shell.env` so it honors a sandbox's virtualized environment
    /// (mirrors `HostsFileStore.defaultPath`).
    static func defaultDirectory() -> URL {
        let configDir: URL
        if let xdg = Shell.env("XDG_CONFIG_HOME"), !xdg.isEmpty {
            configDir = URL(fileURLWithPath: xdg, isDirectory: true)
        } else if let home = Shell.env("HOME"), !home.isEmpty {
            configDir = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
        } else {
            // Shell.homeDirectory handles iOS availability internally.
            configDir = Shell.homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
        }
        return configDir.appendingPathComponent("swiftports", isDirectory: true)
    }
}
