import Foundation
import Sandbox

/// Picks the right `SecretStore` for the current platform. Used as
/// the default when no embedder-provided store is configured.
///
/// - Apple platforms:  `KeychainSecretStore`
/// - Everywhere else:  `InMemorySecretStore` (with a warning logged)
///
/// A future libsecret-backed impl will replace the Linux fallback.
public enum DefaultSecretStore {
    public static func make() -> any SecretStore {
        #if canImport(Security)
        return KeychainSecretStore()
        #else
        Stdio.stderr.write(Data(
            ("warning: no persistent secret store available on this " +
             "platform; tokens will not survive across runs.\n").utf8))
        return InMemorySecretStore()
        #endif
    }
}
