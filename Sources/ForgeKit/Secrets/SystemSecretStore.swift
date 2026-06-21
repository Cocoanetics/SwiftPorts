import Foundation
import ShellKit

/// The platform's default persistent secret store, resolved once at
/// construction. Prefers the native OS keyring, falls back to a `0600`
/// file, and only as a last resort keeps secrets in memory:
///
///   - Apple (macOS / iOS / …): ``KeychainSecretStore`` (Security framework)
///   - Linux:                   ``LibSecretStore`` when a Secret Service
///                              (GNOME Keyring / KWallet) is reachable,
///                              else ``FileSecretStore``
///   - Windows:                 ``WindowsCredentialStore`` (Credential Manager)
///   - Android / other:         ``FileSecretStore`` (app-private; on Android
///                              this is FBE-encrypted at rest)
///
/// Embedders that want a specific backend — an Android Keystore bridge, or
/// an `InMemorySecretStore` for tests — construct it directly and pass it
/// wherever a `SecretStore` is accepted. `SystemSecretStore` is only the
/// default.
public struct SystemSecretStore: SecretStore {
    private let backend: any SecretStore

    /// Resolve and bind the backend for the current platform/runtime.
    public init() {
        self.backend = Self.resolveBackend()
    }

    /// Shared default instance. Backend resolution — including the Linux
    /// Secret Service probe and any fallback warning — happens once, on
    /// first access.
    public static let shared = SystemSecretStore()

    public func get(service: String, account: String) async throws -> String? {
        try await backend.get(service: service, account: account)
    }

    public func set(service: String, account: String, secret: String) async throws {
        try await backend.set(service: service, account: account, secret: secret)
    }

    public func delete(service: String, account: String) async throws {
        try await backend.delete(service: service, account: account)
    }

    // MARK: - Backend selection

    private static func resolveBackend() -> any SecretStore {
        #if canImport(Security)
        return KeychainSecretStore()
        #elseif os(Linux)
        if LibSecretStore.isAvailable {
            return LibSecretStore()
        }
        warn("no Secret Service (keyring) reachable; storing tokens in a "
             + "plaintext 0600 file. Unlock a login keyring, or set "
             + "GH_TOKEN / GITLAB_TOKEN, to keep tokens off disk.")
        return fileFallback()
        #elseif os(Windows)
        return WindowsCredentialStore()
        #else
        // Android & friends: app-private file. On Android this lands in
        // FBE Credential-Encrypted storage (encrypted at rest, per-UID
        // sandboxed), so it's the expected backend — no warning.
        return fileFallback()
        #endif
    }

    /// A `FileSecretStore`, or `InMemorySecretStore` if its directory
    /// can't be created (e.g. a read-only filesystem) — the only case
    /// where tokens won't survive across runs.
    private static func fileFallback() -> any SecretStore {
        let store = FileSecretStore()
        do {
            try FileManager.default.createDirectory(
                at: store.fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return store
        } catch {
            warn("no writable config directory; tokens will not survive "
                 + "across runs (\(error.localizedDescription)).")
            return InMemorySecretStore()
        }
    }

    private static func warn(_ message: String) {
        Shell.current.stderr.write(Data("warning: \(message)\n".utf8))
    }
}
