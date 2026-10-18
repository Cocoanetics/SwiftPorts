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
///
/// The source remembers the `Shell` that was current where it was created — the connecting
/// command's own context — and re-binds it around every `next()` (issue #121). `next()` is driven
/// from an unstructured `Task` that `SSHPublicKeyAuthenticationDelegate` spawns on a NIO event-loop
/// callback, and such a task inherits no task-locals: without the re-binding, `~`, relative paths
/// and the sandbox gate (`Shell.homeDirectory` / `Shell.resolve` / `Shell.authorize`) would all
/// resolve against `Shell.processDefault` — an embedder's app container on iOS, the host user's
/// real `~/.ssh` on macOS — instead of the shell the command runs in.
final class SSHLazyIdentitySource: @unchecked Sendable {
    private let paths: [String]
    private let passphrasePrompt: IdentityLoader.PassphrasePrompt
    private let shell: Shell
    private let lock = NSLock()
    private var nextPathIndex = 0

    /// - parameter shell: the shell identity paths resolve and authorize against; defaults to the
    ///   caller's `Shell.current`, evaluated at the call site.
    init(paths: [String], passphrasePrompt: @escaping IdentityLoader.PassphrasePrompt, shell: Shell = .current) {
        self.paths = paths
        self.passphrasePrompt = passphrasePrompt
        self.shell = shell
    }

    /// The next identity to offer, or `nil` once every path has been tried or skipped.
    func next() async throws -> NIOSSHPrivateKey? {
        try await self.shell.withCurrent {
            try await self.nextInBoundShell()
        }
    }

    private func nextInBoundShell() async throws -> NIOSSHPrivateKey? {
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
