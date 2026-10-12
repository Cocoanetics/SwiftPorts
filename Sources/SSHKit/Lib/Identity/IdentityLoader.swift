import Foundation
import NIOSSH
import ShellKit

/// Loads an `OPENSSH PRIVATE KEY` file (ed25519 or ECDSA, optionally encrypted) into a signing
/// `NIOSSHPrivateKey`. RSA and security-key (`_sk`) files are out of scope for this port
/// (issue #112) and raise `SSHError.unsupportedKeyFormat`.
public enum IdentityLoader {
    /// Returns the passphrase to try for `path`, or `nil`/empty to give up on this identity file —
    /// the moral equivalent of `ssh(1)`'s own prompt returning an empty string
    /// (`sshconnect2.c`'s `load_identity_file`, "no passphrase given, try next key").
    public typealias PassphrasePrompt = @Sendable (_ path: String) async -> String?

    /// Matches `ssh(1)`'s hardcoded default, `NumberOfPasswordPrompts 3` (`readconf.c`): up to 3
    /// interactive retries after the initial empty-passphrase attempt every identity file gets
    /// (`load_identity_file`'s `for (i = 0; i <= options.number_of_password_prompts; i++)`).
    private static let maximumPasswordPrompts = 3

    public static func load(
        path: String,
        passphrasePrompt: @escaping PassphrasePrompt = SSHPassphrasePrompt.readFromTTY
    ) async throws -> NIOSSHPrivateKey {
        let url = Shell.resolve(SSHPath.expandingTilde(path))
        try await Shell.authorize(url)

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SSHError.identityFileNotFound(path: path)
        }

        let contents = try String(contentsOf: url, encoding: .utf8)

        // `load_identity_file` always tries an empty passphrase first — it covers both a
        // genuinely unencrypted key and the rare encrypted key with an empty passphrase — before
        // ever prompting (`sshconnect2.c` lines 1550-1551).
        var passphrase = ""
        for attempt in 0...Self.maximumPasswordPrompts {
            if attempt > 0 {
                guard let entered = await passphrasePrompt(path), !entered.isEmpty else {
                    throw SSHIdentityDecryptionError.declined(path: path)
                }
                passphrase = entered
            }
            do {
                return try OpenSSHPrivateKeyFile.parse(contents, path: path, passphrase: passphrase)
            } catch is SSHIdentityDecryptionError {
                // Covers both a wrong passphrase and the hardcoded empty-passphrase attempt
                // (`attempt == 0`) hitting an encrypted key — either way, this specific attempt
                // failed and the loop should move on to prompting (or exhaust its retry budget).
                continue
            }
        }
        throw SSHIdentityDecryptionError.wrongPassphrase(path: path)
    }

    /// Loads every path in `paths` that exists on disk, skipping the rest. Matches `ssh(1)`
    /// silently skipping an absent candidate from its default `IdentityFile` list — only an
    /// explicitly configured, missing `IdentityFile` is an error (via `load(path:)` directly). An
    /// encrypted identity whose passphrase is declined or never guessed correctly is skipped the
    /// same way `load_identity_file` returning `NULL` leaves it out of the identity list, rather
    /// than aborting the whole connection attempt.
    public static func loadAvailable(
        paths: [String],
        passphrasePrompt: @escaping PassphrasePrompt = SSHPassphrasePrompt.readFromTTY
    ) async throws -> [NIOSSHPrivateKey] {
        var keys: [NIOSSHPrivateKey] = []
        for path in paths {
            let url = Shell.resolve(SSHPath.expandingTilde(path))
            try await Shell.authorize(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            do {
                try await keys.append(Self.load(path: path, passphrasePrompt: passphrasePrompt))
            } catch is SSHIdentityDecryptionError {
                continue
            }
        }
        return keys
    }
}
