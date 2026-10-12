import Foundation
import NIOCore
import NIOSSH

/// Offers each configured identity in order, matching `ssh(1)`'s "try identities in
/// `IdentityFile` config order, public key only" behavior (issue #112's scope — no password,
/// keyboard-interactive, or host-based auth).
///
/// `NIOSSH`'s user-auth state machine calls `nextAuthenticationType` once per attempt — once
/// initially and again after every `SSH2_MSG_USERAUTH_FAILURE` — so offering the next identity on
/// each call naturally reproduces `ssh(1)`'s "try the next key after a rejection" loop. For a
/// `.lazy` source (issue #115), that per-attempt timing is also what keeps decryption honest: a
/// `pty-req`/exec/shell never even starts until this delegate's own channel-open succeeds, and
/// `nextAuthenticationType` itself is never called before `SSHHostKeyVerifier` has already
/// resolved the connection's `completionPromise` — so an identity's passphrase is never prompted
/// for before host-key verification (or the TCP connection) has succeeded, and never for an
/// identity past the one that actually authenticates, matching `pubkey_prepare`/`userauth_pubkey`
/// (`sshconnect2.c`): only the public key is loaded up front there, with the private key decrypted
/// lazily per attempt.
///
/// `swift-nio-ssh` 0.15.0 has no handling for the "no further offer" case this delegate reports by
/// succeeding `nextChallengePromise` with `nil`: `NIOSSHHandler.processInboundMessageResult`'s
/// `.possibleFutureMessage` case literally does nothing when the mapped message is `nil`
/// (`Sources/NIOSSH/NIOSSHHandler.swift`, the `case .success(.none): // Do nothing` branch) — the
/// connection is simply left open forever, mid-handshake, with no further protocol activity on
/// either side. `exhaustedPromise` is this delegate's own workaround: `SSHClient` races it against
/// the channel-open future so `exec(_:)` fails promptly with `SSHError.permissionDenied` instead of
/// hanging, and closes the connection once exhaustion fires.
final class SSHPublicKeyAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    /// Where identities come from: already-decrypted (e.g. `GitKitSSH`'s non-interactive callers,
    /// which load every identity up front) or decrypted lazily, one per offer, from disk.
    enum Source {
        case preloaded([NIOSSHPrivateKey])
        case lazy(SSHLazyIdentitySource)
    }

    private let username: String
    private let source: Source
    private let lock = NSLock()
    private var nextPreloadedIndex = 0

    /// Set once every identity has been offered and rejected — `userauth()` in `sshconnect2.c`
    /// line 543 is the equivalent moment real `ssh` calls `fatal("... Permission denied (%s).",
    /// authlist)`.
    private var _exhausted = false
    var exhausted: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self._exhausted
    }

    /// Resolved the moment `exhausted` becomes true — see the type-level note.
    let exhaustedPromise: EventLoopPromise<Void>

    init(username: String, identities: [NIOSSHPrivateKey], exhaustedPromise: EventLoopPromise<Void>) {
        self.username = username
        self.source = .preloaded(identities)
        self.exhaustedPromise = exhaustedPromise
    }

    init(username: String, identitySource: SSHLazyIdentitySource, exhaustedPromise: EventLoopPromise<Void>) {
        self.username = username
        self.source = .lazy(identitySource)
        self.exhaustedPromise = exhaustedPromise
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            self.finishExhausted(nextChallengePromise)
            return
        }

        switch self.source {
        case .preloaded(let identities):
            self.lock.lock()
            let index = self.nextPreloadedIndex
            self.nextPreloadedIndex += 1
            self.lock.unlock()

            guard index < identities.count else {
                self.finishExhausted(nextChallengePromise)
                return
            }
            nextChallengePromise.succeed(self.makeOffer(identities[index]))

        case .lazy(let identitySource):
            // `EventLoopPromise.succeed`/`.fail` are documented safe from any thread, so resolving
            // this from an unstructured `Task` (off the calling `EventLoop`) is fine — the whole
            // point here is that decrypting the next identity is `async` (it may need a TTY
            // passphrase prompt) and must not block the `EventLoop` driving the handshake.
            Task {
                do {
                    guard let identity = try await identitySource.next() else {
                        self.finishExhausted(nextChallengePromise)
                        return
                    }
                    nextChallengePromise.succeed(self.makeOffer(identity))
                } catch {
                    nextChallengePromise.fail(error)
                }
            }
        }
    }

    private func finishExhausted(_ nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        self.lock.lock()
        self._exhausted = true
        self.lock.unlock()
        nextChallengePromise.succeed(nil)
        self.exhaustedPromise.succeed(())
    }

    private func makeOffer(_ identity: NIOSSHPrivateKey) -> NIOSSHUserAuthenticationOffer {
        NIOSSHUserAuthenticationOffer(
            username: self.username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: identity))
        )
    }
}
