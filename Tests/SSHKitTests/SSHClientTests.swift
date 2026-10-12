// `swift-nio-ssh` 0.15.0's own `CSPRNG` traps on any platform other than Darwin/Linux/Android
// (`Sources/NIOSSH/CSPRNG.swift`: `#if canImport(Darwin) || os(Linux) || os(Android)` else
// `fatalError("Platform does not have a supported CSPRNG")`) — confirmed by `build-windows` CI
// crashing with that exact message the moment a real SSH handshake (KEX) runs. Every test here
// either performs a full handshake or installs a client-side `NIOSSHHandler`, so the whole suite
// is gated off Windows until upstream adds a Windows CSPRNG; see Docs/SSH.md.
#if !os(Windows)
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import SSHKit

@Suite("SSHClient (in-process NIOSSH server)")
struct SSHClientTests {
    @Test func execRoundTrip() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: server.port),
            publicKey: server.hostKey.publicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let exec = try await client.exec("echo hello")

        var stdout: [UInt8] = []
        for await chunk in exec.stdout {
            stdout.append(contentsOf: chunk)
        }
        let exitStatus = try await exec.exitStatus

        #expect(exitStatus == 0)
        #expect(String(decoding: stdout, as: UTF8.self) == "ran: echo hello\n")

        try await client.close()
    }

    /// `FixedResponseExecHandler` (used by `execRoundTrip` above) responds and closes immediately,
    /// simulating a command that doesn't read stdin — so writing to stdin afterward would race its
    /// close, the same way writing to a real `ssh host echo hi`'s stdin after it's already exited
    /// would. This test instead uses `.echoStdin`, which waits for the client's EOF before
    /// responding, to exercise `SSHExecChannel.write`/`closeStdin` deterministically.
    @Test func stdinWriteAndCloseRoundTrip() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey, execBehavior: .echoStdin)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: server.port),
            publicKey: server.hostKey.publicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let exec = try await client.exec("cat")
        try await exec.write(Array("hello-stdin\n".utf8))
        try await exec.closeStdin()

        var stdout: [UInt8] = []
        for await chunk in exec.stdout {
            stdout.append(contentsOf: chunk)
        }
        let exitStatus = try await exec.exitStatus

        #expect(exitStatus == 0)
        #expect(String(decoding: stdout, as: UTF8.self) == "hello-stdin\n")

        try await client.close()
    }

    /// `ssh host` with no command — the login-shell / interactive-session face `SSHExecutable`
    /// uses when `arguments.command.isEmpty` (issue #115).
    @Test func shellRoundTrip() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: server.port),
            publicKey: server.hostKey.publicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let shell = try await client.shell()
        #expect(shell.hasPseudoTerminal == false)

        var stdout: [UInt8] = []
        for await chunk in shell.stdout {
            stdout.append(contentsOf: chunk)
        }
        #expect(try await shell.exitStatus == 0)
        #expect(String(decoding: stdout, as: UTF8.self) == "shell\n")

        try await client.close()
    }

    /// `ssh -t host command` — a `pty-req` accepted by the peer, then `exec`, on the same channel.
    @Test func execWithAcceptedPseudoTerminalRoundTrips() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: server.port),
            publicKey: server.hostKey.publicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        let exec = try await client.exec("echo hello", pseudoTerminal: pty, pseudoTerminalRequired: true)
        #expect(exec.hasPseudoTerminal)

        var stdout: [UInt8] = []
        for await chunk in exec.stdout {
            stdout.append(contentsOf: chunk)
        }
        #expect(try await exec.exitStatus == 0)
        #expect(String(decoding: stdout, as: UTF8.self) == "ran: echo hello\n")

        try await client.close()
    }

    /// `ssh -t host command` against a server that rejects `pty-req`: fatal, matching
    /// `client_status_confirm` elevating `CONFIRM_TTY` to `CONFIRM_CLOSE` for an explicit request
    /// (`clientloop.c`).
    @Test func explicitPseudoTerminalRejectionThrows() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey, execBehavior: .rejectPseudoTerminal)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: server.port),
            publicKey: server.hostKey.publicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))

        await #expect(throws: SSHClientChannelError.pseudoTerminalRequestFailed) {
            _ = try await client.exec("echo hello", pseudoTerminal: pty, pseudoTerminalRequired: true)
        }

        try await client.close()
    }

    /// An automatically-requested PTY (not `-t`) rejected by the peer falls back to a PTY-less
    /// session on the *same* channel, silently — matching `client_status_confirm`'s non-fatal
    /// `CONFIRM_TTY` path, which just calls `leave_raw_mode(0)` and carries on.
    @Test func automaticPseudoTerminalRejectionFallsBackSilently() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey, execBehavior: .rejectPseudoTerminal)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: server.port),
            publicKey: server.hostKey.publicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:]))
        let shell = try await client.shell(pseudoTerminal: pty, pseudoTerminalRequired: false)
        #expect(shell.hasPseudoTerminal == false)

        var stdout: [UInt8] = []
        for await chunk in shell.stdout {
            stdout.append(contentsOf: chunk)
        }
        #expect(try await shell.exitStatus == 0)
        #expect(String(decoding: stdout, as: UTF8.self) == "shell\n")

        try await client.close()
    }

    @Test func hostKeyMismatchFailsClosed() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        let wrongHostKey = NIOSSHPrivateKey(ed25519Key: .init())
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost("127.0.0.1", publicKey: wrongHostKey.publicKey, hashed: false)

        await #expect(throws: SSHError.self) {
            _ = try await SSHClient.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sshkit-tests",
                identities: [identity],
                knownHosts: knownHosts,
                strictHostKeyChecking: .yes
            )
        }
    }

    @Test func newHostUnderStrictYesFailsClosed() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))

        await #expect(throws: SSHError.self) {
            _ = try await SSHClient.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sshkit-tests",
                identities: [identity],
                knownHosts: KnownHostsStore(),
                strictHostKeyChecking: .yes
            )
        }
    }

    @Test func newHostUnderAcceptNewSucceeds() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: KnownHostsStore(),
            strictHostKeyChecking: .acceptNew
        )
        try await client.close()
    }

    @Test func exhaustedIdentitiesSurfacesPermissionDenied() async throws {
        let server = try await InProcessSSHServer.start(authentication: .rejectAll)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost(
            SSHKnownHostsName.make(host: "127.0.0.1", port: server.port),
            publicKey: server.hostKey.publicKey,
            hashed: false
        )

        let client = try await SSHClient.connect(
            host: "127.0.0.1",
            port: server.port,
            username: "sshkit-tests",
            identities: [identity],
            knownHosts: knownHosts,
            strictHostKeyChecking: .yes
        )

        await #expect(throws: SSHError.self) {
            _ = try await client.exec("echo hello")
        }

        // The auth-exhaustion workaround already closed `channel` internally (see the note on
        // `SSHPublicKeyAuthenticationDelegate`) — `close()` must still succeed (and actually shut
        // down the event loop group) instead of throwing `ChannelError.alreadyClosed` and leaking
        // the connection's dedicated thread.
        try await client.close()
    }

    /// A nondefault-port known-hosts entry recorded under the bare hostname (no `[host]:port`
    /// bracketing) must not satisfy strict checking — it's the wrong lookup key, matching
    /// `put_host_port()` in `misc.c`, not an entry for this destination at all.
    @Test func bareHostnameEntryDoesNotMatchNondefaultPort() async throws {
        let server = try await InProcessSSHServer.start(authentication: .acceptAnyPublicKey)
        defer { Task { try? await server.shutdown() } }

        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        var knownHosts = KnownHostsStore()
        knownHosts.recordNewHost("127.0.0.1", publicKey: server.hostKey.publicKey, hashed: false)

        await #expect(throws: SSHError.self) {
            _ = try await SSHClient.connect(
                host: "127.0.0.1",
                port: server.port,
                username: "sshkit-tests",
                identities: [identity],
                knownHosts: knownHosts,
                strictHostKeyChecking: .yes
            )
        }
    }

    /// If the TCP connection comes up but the peer closes it immediately — before any SSH version
    /// exchange, and therefore before `validateHostKey` ever runs — nothing else resolves the
    /// host-key verifier's completion promise. `connect(...)` must still fail promptly instead of
    /// hanging forever.
    @Test func connectionClosedBeforeHostKeyVerificationDoesNotHang() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { Task { try? await group.shutdownGracefully() } }

        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.close(promise: nil)
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        defer { Task { try? await listener.close().get() } }

        let port = listener.localAddress?.port ?? 0
        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))

        await #expect(throws: Error.self) {
            _ = try await SSHClient.connect(
                host: "127.0.0.1",
                port: port,
                username: "sshkit-tests",
                identities: [identity],
                knownHosts: KnownHostsStore(),
                strictHostKeyChecking: .yes
            )
        }
    }

    /// Cancelling a connect after TCP acceptance but before the peer sends an SSH version used to
    /// abandon the host-key-completion and authentication-exhaustion promises. In debug builds,
    /// their later deinitialization trapped with NIO's "leaking promise" fatal error.
    @Test func abandonedConnectMidHandshakeSettlesPromises() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let acceptedPromise = group.next().makePromise(of: Void.self)
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                acceptedPromise.succeed(())
                // Deliberately leave the connection open without an SSH version exchange.
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()

        let port = listener.localAddress?.port ?? 0
        let identity = try await IdentityLoader.load(path: SSHKitFixtures.path("id_ed25519_test"))
        let connect = Task {
            try await SSHClient.connect(
                host: "127.0.0.1",
                port: port,
                username: "sshkit-tests",
                identities: [identity],
                knownHosts: KnownHostsStore(),
                strictHostKeyChecking: .yes
            )
        }

        try await acceptedPromise.futureResult.get()
        connect.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await connect.value
        }

        try await listener.close().get()
        try await group.shutdownGracefully()
    }
}
#endif
