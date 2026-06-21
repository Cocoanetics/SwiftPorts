import Foundation
import ShellKit

/// Cross-platform persistent `SecretStore` backed by a single JSON file
/// with `0600` permissions. This is the fallback used when no OS keyring
/// is reachable — headless Linux without a Secret Service daemon, or
/// Android without an embedder-injected Keystore store.
///
/// It mirrors what `git credential-store` and upstream `glab` do by
/// default: the secret is protected by file permissions plus the OS's
/// per-user / per-app sandbox, not by additional encryption.
///
/// On Android the natural `directory` is the app's private
/// `Context.filesDir`. Files there inherit OS at-rest encryption
/// (File-Based Encryption / Credential-Encrypted storage, keyed to the
/// user's lock credential and protected by the TEE) and per-UID
/// sandboxing — so an embedder should pass that directory. On a desktop
/// the file is genuinely plaintext-at-rest, which is why a native store
/// (Keychain / libsecret / Credential Manager) is always preferred when
/// available; see ``SystemSecretStore``.
///
/// The on-disk layout is a nested map `service → account → secret`, so
/// neither identifier needs escaping:
///
///     {
///       "com.swiftgh.gh": { "github.com": "ghp_…" },
///       "com.swiftgl.glab": { "gitlab.com": "glpat_…" }
///     }
public final class FileSecretStore: SecretStore, @unchecked Sendable {
    /// The backing file, `<directory>/secrets.json`.
    public let fileURL: URL

    // Guards read-modify-write against concurrent in-process access.
    // `NSLock.withLock` keeps the package OS floor low (same rationale
    // as `InMemorySecretStore`). Cross-process races aren't guarded —
    // matching `git credential-store`.
    private let lock = NSLock()

    /// - Parameter directory: the directory that holds `secrets.json`.
    ///   Defaults to `<XDG_CONFIG_HOME | $HOME/.config>/swiftports`.
    ///   Tests inject a temp dir; Android embedders pass `filesDir`.
    public init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        self.fileURL = dir.appendingPathComponent("secrets.json", isDirectory: false)
    }

    public func get(service: String, account: String) async throws -> String? {
        lock.withLock { load()[service]?[account] }
    }

    public func set(service: String, account: String, secret: String) async throws {
        try lock.withLock {
            var table = load()
            table[service, default: [:]][account] = secret
            try save(table)
        }
    }

    public func delete(service: String, account: String) async throws {
        try lock.withLock {
            var table = load()
            guard table[service]?[account] != nil else { return }  // no-op if absent
            table[service]?[account] = nil
            if table[service]?.isEmpty == true { table[service] = nil }
            try save(table)
        }
    }

    // MARK: - File I/O (callers must hold `lock`)

    /// Decode the on-disk table. A missing *or corrupt* file is treated
    /// as empty so a single bad write can't permanently wedge the store.
    private func load() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    private func save(_ table: [String: [String: String]]) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(table)
        try data.write(to: fileURL, options: .atomic)
        // Tighten to owner-only after the atomic rename.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func ensureDirectory() throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
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
