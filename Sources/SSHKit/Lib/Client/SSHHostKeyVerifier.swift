import NIOCore
import NIOSSH

/// Verifies a server's host key against `known_hosts`, applying `StrictHostKeyChecking` the way
/// `check_host_key()` in `sshconnect.c` (lines 984-1413) does. This port has no TTY/prompt
/// plumbing (that's `SSHCommand`'s concern — #114), so the interactive `ask` confirmation
/// (`sshconnect.c` lines 1207-1254) is never offered: a new host under `.ask` fails exactly the
/// way real `ssh` does under `BatchMode=yes` or a non-tty stdin, where `confirm()` silently
/// returns "no" (`sshconnect.c` line 610-611) without printing the "Are you sure..." prompt text.
///
/// Scoped to this port's `known_hosts` subset: no `@cert-authority`/`@revoked` markers, no
/// `CheckHostIP`, no DNS (`VerifyHostKeyDNS`), no visual host key — none of which issue #112 asks
/// for.
final class SSHHostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let userKnownHostsFilePath: String?
    private let policy: SSHStrictHostKeyChecking

    private(set) var knownHosts: KnownHostsStore

    /// Set when `validateHostKey` fails the promise, so `SSHClient` can surface the precise,
    /// OpenSSH-worded error instead of whatever generic error the resulting connection teardown
    /// produces.
    private(set) var lastError: SSHError?

    /// Set when a new host key is accepted and should be appended to `userKnownHostsFilePath`.
    /// `SSHClient` persists this after the synchronous delegate callback returns (`KnownHostsStore`
    /// is documented as sync in-memory / async on-disk — see its type-level note).
    private(set) var pendingPersist: KnownHostsEntry?

    /// Resolved the moment `validateHostKey` decides, success or failure — created up front (before
    /// the connection attempt starts) so `SSHClient.connect` can await it immediately after the TCP
    /// connection comes up, with no race against the callback firing first.
    let completionPromise: EventLoopPromise<Void>

    init(
        host: String,
        knownHosts: KnownHostsStore,
        userKnownHostsFilePath: String?,
        policy: SSHStrictHostKeyChecking,
        completionPromise: EventLoopPromise<Void>
    ) {
        self.host = host
        self.knownHosts = knownHosts
        self.userKnownHostsFilePath = userKnownHostsFilePath
        self.policy = policy
        self.completionPromise = completionPromise
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let matches = self.knownHosts.matchingEntries(forHost: self.host)

        if matches.contains(where: { $0.publicKey == hostKey }) {
            validationCompletePromise.succeed(())
            self.completionPromise.succeed(())
            return
        }

        if matches.isEmpty {
            self.handleNewHost(hostKey: hostKey, validationCompletePromise: validationCompletePromise)
        } else {
            self.handleChangedHost(hostKey: hostKey, previouslyKnown: matches[0], validationCompletePromise: validationCompletePromise)
        }
    }

    private func handleNewHost(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        switch self.policy {
        case .yes:
            // `sshconnect.c` lines 1204-1206.
            let type = SSHPublicKeyDescribing.shortTypeName(for: hostKey)
            self.fail(
                lines: ["No \(type) host key is known for \(self.host) and you have requested strict checking."],
                validationCompletePromise: validationCompletePromise
            )
        case .ask:
            // No TTY to prompt on; `confirm()` silently declines under `BatchMode` (see type doc).
            self.fail(lines: [], validationCompletePromise: validationCompletePromise)
        case .no, .acceptNew:
            // `sshconnect.c` lines 1259-1285: silently trust and record, no prompt, no banner.
            let entry = self.knownHosts.recordNewHost(self.host, publicKey: hostKey, hashed: false)
            self.pendingPersist = entry
            validationCompletePromise.succeed(())
            self.completionPromise.succeed(())
        }
    }

    private func handleChangedHost(
        hostKey: NIOSSHPublicKey,
        previouslyKnown: KnownHostsEntry,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        guard self.policy != .no else {
            // `sshconnect.c` line 1356: only `StrictHostKeyChecking no` lets a changed key through,
            // unconditionally and without recording it.
            validationCompletePromise.succeed(())
            self.completionPromise.succeed(())
            return
        }

        // `warn_changed_key()`, `sshconnect.c` lines 1715-1736, plus the trailing offending-key
        // note from `check_host_key()` lines 1342-1350.
        let lines = [
            "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@",
            "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @",
            "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@",
            "IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!",
            "Someone could be eavesdropping on you right now (man-in-the-middle attack)!",
            "It is also possible that a host key has just been changed.",
            "The fingerprint for the \(SSHPublicKeyDescribing.shortTypeName(for: hostKey)) key sent by the remote host is\n\(SSHPublicKeyDescribing.sha256Fingerprint(for: hostKey)).",
            "Please contact your system administrator.",
            "Add correct host key in \(previouslyKnown.sourceDescription) to get rid of this message.",
            "Offending \(SSHPublicKeyDescribing.shortTypeName(for: previouslyKnown.publicKey)) key in \(previouslyKnown.sourceDescription):\(previouslyKnown.lineNumber)",
        ]
        self.fail(lines: lines, validationCompletePromise: validationCompletePromise)
    }

    private func fail(lines: [String], validationCompletePromise: EventLoopPromise<Void>) {
        let error = SSHError.hostKeyVerificationFailed(lines: lines)
        self.lastError = error
        validationCompletePromise.fail(error)
        self.completionPromise.fail(error)
    }
}
