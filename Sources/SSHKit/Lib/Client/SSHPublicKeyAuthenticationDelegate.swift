import NIOCore
import NIOSSH

/// Offers each configured identity in order, matching `ssh(1)`'s "try identities in
/// `IdentityFile` config order, public key only" behavior (issue #112's scope — no password,
/// keyboard-interactive, or host-based auth).
///
/// `NIOSSH`'s user-auth state machine calls `nextAuthenticationType` once per attempt — once
/// initially and again after every `SSH2_MSG_USERAUTH_FAILURE` — so offering the next identity on
/// each call naturally reproduces `ssh(1)`'s "try the next key after a rejection" loop.
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
    private let username: String
    private let identities: [NIOSSHPrivateKey]
    private var nextIndex = 0

    /// Set once every identity has been offered and rejected — `userauth()` in `sshconnect2.c`
    /// line 543 is the equivalent moment real `ssh` calls `fatal("... Permission denied (%s).",
    /// authlist)`.
    private(set) var exhausted = false

    /// Resolved the moment `exhausted` becomes true — see the type-level note.
    let exhaustedPromise: EventLoopPromise<Void>

    init(username: String, identities: [NIOSSHPrivateKey], exhaustedPromise: EventLoopPromise<Void>) {
        self.username = username
        self.identities = identities
        self.exhaustedPromise = exhaustedPromise
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), self.nextIndex < self.identities.count else {
            self.exhausted = true
            nextChallengePromise.succeed(nil)
            self.exhaustedPromise.succeed(())
            return
        }

        let identity = self.identities[self.nextIndex]
        self.nextIndex += 1
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: self.username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: identity))
            )
        )
    }
}
