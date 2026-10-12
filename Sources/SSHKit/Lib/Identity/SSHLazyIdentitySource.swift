import Foundation
import NIOSSH
import ShellKit

/// Lazily decrypts identities from `paths`, one at a time, in order — mirrors `ssh(1)`'s own
/// `pubkey_prepare`/`userauth_pubkey` loop (`sshconnect2.c`): an identity file isn't read (and its
/// passphrase isn't prompted for) until `SSHClient`'s authentication delegate is actually ready to
/// offer it — which only happens once host-key verification has already succeeded, and only for
/// the Nth identity if the first N-1 were already rejected by the server. A path that doesn't
/// exist, or whose passphrase is never obtained, is skipped — the same "move on, don't abort"
/// behavior `IdentityLoader.loadAvailable` has, just spread out over the authentication attempts
/// instead of resolved all at once before the connection even starts.
final class SSHLazyIdentitySource: @unchecked Sendable {
    private let paths: [String]
    private let passphrasePrompt: IdentityLoader.PassphrasePrompt
    private let lock = NSLock()
    private var nextPathIndex = 0

    init(paths: [String], passphrasePrompt: @escaping IdentityLoader.PassphrasePrompt) {
        self.paths = paths
        self.passphrasePrompt = passphrasePrompt
    }

    /// The next identity to offer, or `nil` once every path has been tried or skipped.
    func next() async throws -> NIOSSHPrivateKey? {
        while let path = self.claimNextPath() {
            let url = Shell.resolve(SSHPath.expandingTilde(path))
            try await Shell.authorize(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            do {
                return try await IdentityLoader.load(path: path, passphrasePrompt: self.passphrasePrompt)
            } catch is SSHIdentityDecryptionError {
                continue
            }
        }
        return nil
    }

    /// Atomically claims the next not-yet-tried path, or `nil` once exhausted. A plain
    /// (non-`async`) method, since `NSLock.lock()`/`unlock()` can't be called directly from an
    /// `async` context.
    private func claimNextPath() -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.nextPathIndex < self.paths.count else {
            return nil
        }
        let path = self.paths[self.nextPathIndex]
        self.nextPathIndex += 1
        return path
    }
}
