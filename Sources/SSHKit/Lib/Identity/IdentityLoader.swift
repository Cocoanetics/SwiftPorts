import Foundation
import NIOSSH
import ShellKit

/// Loads an unencrypted `OPENSSH PRIVATE KEY` file (ed25519 or ECDSA) into a signing
/// `NIOSSHPrivateKey`. RSA, security-key (`_sk`), and encrypted keys are out of scope for this
/// port (issue #112) and raise `SSHError.unsupportedKeyFormat`.
public enum IdentityLoader {
    public static func load(path: String) async throws -> NIOSSHPrivateKey {
        let url = Shell.resolve(SSHPath.expandingTilde(path))
        try await Shell.authorize(url)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SSHError.identityFileNotFound(path: path)
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        return try OpenSSHPrivateKeyFile.parse(contents, path: path)
    }

    /// Loads every path in `paths` that exists on disk, skipping the rest. Matches `ssh(1)`
    /// silently skipping an absent candidate from its default `IdentityFile` list — only an
    /// explicitly configured, missing `IdentityFile` is an error (via `load(path:)` directly).
    public static func loadAvailable(paths: [String]) async throws -> [NIOSSHPrivateKey] {
        var keys: [NIOSSHPrivateKey] = []
        for path in paths {
            let url = Shell.resolve(SSHPath.expandingTilde(path))
            try await Shell.authorize(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            try await keys.append(Self.load(path: path))
        }
        return keys
    }
}
