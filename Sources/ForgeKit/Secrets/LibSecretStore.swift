#if os(Linux)
import Foundation
import CSecretShim

/// Linux `SecretStore` backed by the Secret Service (GNOME Keyring /
/// KWallet) through libsecret, via the `CSecretShim` C wrappers.
///
/// This is the direct equivalent of what upstream `gh`/`glab` get from
/// `zalando/go-keyring` on Linux — the token lands in the user's
/// unlocked keyring rather than a plaintext file. When no Secret Service
/// is running (headless server, container, CI), ``isAvailable`` is false
/// and ``SystemSecretStore`` falls back to ``FileSecretStore``.
public struct LibSecretStore: SecretStore {
    public init() {}

    public func get(service: String, account: String) async throws -> String? {
        var status: Int32 = 0
        let value = swiftports_secret_lookup(service, account, &status)
        if status < 0 {
            throw SecretStoreError.backendError(
                status: status, message: "libsecret lookup failed")
        }
        guard let value else { return nil }   // status == 0: not found
        defer { swiftports_secret_free(value) }
        return String(cString: value)
    }

    public func set(service: String, account: String, secret: String) async throws {
        let rc = swiftports_secret_store(
            service, account, "SwiftPorts (\(service))", secret)
        guard rc == 0 else {
            throw SecretStoreError.backendError(
                status: rc, message: "libsecret store failed")
        }
    }

    public func delete(service: String, account: String) async throws {
        let rc = swiftports_secret_clear(service, account)
        guard rc == 0 else {
            throw SecretStoreError.backendError(
                status: rc, message: "libsecret clear failed")
        }
    }

    /// Whether the Secret Service is reachable on this machine. Used by
    /// ``SystemSecretStore`` to choose the file fallback on headless
    /// boxes (no D-Bus session bus / keyring daemon).
    public static var isAvailable: Bool {
        swiftports_secret_available() != 0
    }
}
#endif
