import NIOCore
import NIOPosix
import NIOSSH

/// An in-process, OpenSSH-compatible SSH client connection: TCP connect, host-key verification
/// against `known_hosts`, and public-key user authentication, on mainline `apple/swift-nio-ssh`
/// (issue #112). `exec(_:)` opens a remote command's exec channel — stdin/stdout/stderr as async
/// byte streams, plus the exit status.
///
/// `connect(...)` returns once the TCP connection is up and host-key verification has resolved
/// (so a bad host key fails here, immediately, the way real `ssh` aborts before user auth even
/// starts). Authentication itself completes lazily: an exhausted-identities failure surfaces the
/// first time `exec(_:)` is called, mirroring `ssh(1)`'s `Permission denied (publickey).` /
/// exit 255 (`sshconnect2.c` line 543).
public final class SSHClient: @unchecked Sendable {
    private let channel: Channel
    private let eventLoopGroup: EventLoopGroup
    private let hostKeyVerifier: SSHHostKeyVerifier
    private let authDelegate: SSHPublicKeyAuthenticationDelegate
    private let username: String
    private let host: String

    private init(
        channel: Channel,
        eventLoopGroup: EventLoopGroup,
        hostKeyVerifier: SSHHostKeyVerifier,
        authDelegate: SSHPublicKeyAuthenticationDelegate,
        username: String,
        host: String
    ) {
        self.channel = channel
        self.eventLoopGroup = eventLoopGroup
        self.hostKeyVerifier = hostKeyVerifier
        self.authDelegate = authDelegate
        self.username = username
        self.host = host
    }

    public static func connect(
        host: String,
        port: Int,
        username: String,
        identities: [NIOSSHPrivateKey],
        knownHosts: KnownHostsStore,
        userKnownHostsFilePath: String? = nil,
        strictHostKeyChecking: SSHStrictHostKeyChecking = .ask
    ) async throws -> SSHClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let completionPromise = group.next().makePromise(of: Void.self)
            let hostKeyVerifier = SSHHostKeyVerifier(
                host: host,
                port: port,
                knownHosts: knownHosts,
                userKnownHostsFilePath: userKnownHostsFilePath,
                policy: strictHostKeyChecking,
                completionPromise: completionPromise
            )
            let authDelegate = SSHPublicKeyAuthenticationDelegate(
                username: username,
                identities: identities,
                exhaustedPromise: group.next().makePromise(of: Void.self)
            )

            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sshHandler = NIOSSHHandler(
                            role: .client(.init(userAuthDelegate: authDelegate, serverAuthDelegate: hostKeyVerifier)),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(sshHandler)
                    }
                }

            let channel = try await bootstrap.connect(host: host, port: port).get()

            // swift-nio-ssh 0.15.0 never closes the connection on its own once identities are
            // exhausted (see the note on `SSHPublicKeyAuthenticationDelegate`) — close it ourselves
            // so the connection doesn't hang open forever even if `exec(_:)` is never called.
            authDelegate.exhaustedPromise.futureResult.whenSuccess { _ in
                channel.close(promise: nil)
            }

            // If the peer disconnects or negotiation fails before `validateHostKey` ever runs,
            // nothing else resolves `completionPromise` — without this, awaiting it below would
            // hang forever instead of surfacing the connection's actual failure.
            channel.closeFuture.whenComplete { _ in
                completionPromise.fail(SSHClientChannelError.connectionClosedBeforeHostKeyVerification)
            }

            do {
                try await completionPromise.futureResult.get()
            } catch {
                try? await channel.close().get()
                throw error
            }

            if let pending = hostKeyVerifier.pendingPersist, let path = userKnownHostsFilePath {
                try? await KnownHostsStore.appendToFile(pending, path: path)
            }

            return SSHClient(
                channel: channel,
                eventLoopGroup: group,
                hostKeyVerifier: hostKeyVerifier,
                authDelegate: authDelegate,
                username: username,
                host: host
            )
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// Runs `command` as a single remote exec channel (RFC 4254 §6.5) — the SSH equivalent of
    /// `ssh host command`.
    public func exec(_ command: String) async throws -> SSHExecChannel {
        let (stdout, stdoutContinuation) = AsyncStream<[UInt8]>.makeStream()
        let (stderr, stderrContinuation) = AsyncStream<[UInt8]>.makeStream()
        let exitStatusPromise = self.channel.eventLoop.makePromise(of: Int32.self)
        let handler = SSHExecChannelHandler(
            stdoutContinuation: stdoutContinuation,
            stderrContinuation: stderrContinuation,
            exitStatusPromise: exitStatusPromise
        )

        // Chained entirely in NIOSSHHandler-returning future below the final `.get()`, since
        // `NIOSSHHandler` is explicitly not `Sendable` and can't cross the `await` boundary itself.
        let channelFuture = self.channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            let channelPromise = self.channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(channelPromise, channelType: .session) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHClientChannelError.unexpectedChannelType)
                }
                return childChannel.eventLoop.makeCompletedFuture {
                    try childChannel.pipeline.syncOperations.addHandler(handler)
                }
            }
            // swift-nio-ssh 0.15.0 never resolves `channelPromise` on its own once identities are
            // exhausted (see the note on `SSHPublicKeyAuthenticationDelegate`) — without this,
            // `channelPromise` leaks (and traps, in debug builds) instead of failing. Resolving the
            // same promise twice is safe: `EventLoopPromise` only honors the first call.
            self.authDelegate.exhaustedPromise.futureResult.whenSuccess {
                channelPromise.fail(SSHClientChannelError.authenticationExhausted)
            }
            return channelPromise.futureResult
        }

        let childChannel: Channel
        do {
            childChannel = try await channelFuture.get()
        } catch {
            // `handler` (and the `exitStatusPromise` it owns) never got installed on any
            // pipeline, so nothing else will ever fulfill it — fail it here instead of leaking.
            exitStatusPromise.fail(error)
            throw self.faithfulError(for: error)
        }

        try await childChannel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)).get()

        return SSHExecChannel(channel: childChannel, stdout: stdout, stderr: stderr, exitStatusPromise: exitStatusPromise)
    }

    /// Closes the connection.
    public func close() async throws {
        do {
            try await self.channel.close().get()
        } catch ChannelError.alreadyClosed {
            // Already torn down — e.g. by the auth-exhaustion workaround on `connect`/`exec`, or by
            // the peer. Not an error a caller should see; fall through to shut down the group.
        }
        try await self.eventLoopGroup.shutdownGracefully()
    }

    /// Translates a generic NIOSSH connection-teardown error into the OpenSSH-exact error for
    /// whichever specific cause (host key or exhausted identities) actually produced it.
    private func faithfulError(for error: Error) -> Error {
        if let hostKeyError = self.hostKeyVerifier.lastError {
            return hostKeyError
        }
        if self.authDelegate.exhausted {
            return SSHError.permissionDenied(user: self.username, host: self.host, methods: ["publickey"])
        }
        return error
    }
}
