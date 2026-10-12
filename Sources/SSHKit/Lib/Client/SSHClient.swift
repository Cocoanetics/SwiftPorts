import Foundation
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
    private static let shutdownQueue = DispatchQueue(label: "SSHKit.SSHClient.shutdown")

    private let channel: Channel
    private let eventLoopGroup: EventLoopGroup
    private let hostKeyVerifier: SSHHostKeyVerifier
    private let authDelegate: SSHPublicKeyAuthenticationDelegate
    private let username: String
    private let host: String
    private let lifecycleLock = NSLock()
    private var closeStarted = false
    private var synchronousShutdownError: Error?

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

    deinit {
        // A caller may abandon a connected client without calling `close()`. Closing here makes
        // the channel's teardown callback settle every connect-time promise before the event-loop
        // group goes away; the callback form never blocks this (possibly event-loop) thread.
        guard self.beginClose() else { return }
        self.channel.close(promise: nil)
        self.channel.closeFuture.whenComplete { [eventLoopGroup] _ in
            eventLoopGroup.shutdownGracefully(queue: SSHClient.shutdownQueue) { _ in }
        }
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
        let completionPromise = group.next().makePromise(of: Void.self)
        let exhaustedPromise = group.next().makePromise(of: Void.self)

        do {
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
                exhaustedPromise: exhaustedPromise
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

            let connectFuture = bootstrap.connect(host: host, port: port)
            let channel = try await withTaskCancellationHandler {
                try await connectFuture.get()
            } onCancel: {
                // `EventLoopFuture.get()` does not cancel its underlying operation. If the task
                // is abandoned while TCP connect is in flight, close a channel that arrives later
                // so neither its handlers nor their promises can leak.
                connectFuture.whenSuccess { channel in
                    channel.close(promise: nil)
                }
            }

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
                exhaustedPromise.fail(SSHClientChannelError.connectionClosed)
            }

            do {
                try await withTaskCancellationHandler {
                    try await completionPromise.futureResult.get()
                } onCancel: {
                    channel.close(promise: nil)
                }
            } catch {
                try? await channel.close().get()
                if Task.isCancelled {
                    throw CancellationError()
                }
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
            completionPromise.fail(error)
            exhaustedPromise.fail(error)
            try? await self.shutdown(group)
            if Task.isCancelled {
                throw CancellationError()
            }
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

        // A successfully opened session proves authentication completed. Settle the exhaustion
        // signal with a failure so its `whenSuccess` teardown hooks stay dormant and the promise
        // cannot remain pending until deallocation.
        self.authDelegate.exhaustedPromise.fail(SSHClientChannelError.authenticationCompleted)

        try await childChannel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)).get()

        return SSHExecChannel(channel: childChannel, stdout: stdout, stderr: stderr, exitStatusPromise: exitStatusPromise)
    }

    /// Closes the connection.
    public func close() async throws {
        guard self.beginClose() else { return }
        do {
            try await self.channel.close().get()
        } catch ChannelError.alreadyClosed {
            // Already torn down — e.g. by the auth-exhaustion workaround on `connect`/`exec`, or by
            // the peer. Not an error a caller should see; fall through to shut down the group.
        }
        try await Self.shutdown(self.eventLoopGroup)
    }

    /// Synchronous teardown for GitKit's synchronous libgit2 transport callback. NIO expressly
    /// permits blocking future waits away from an EventLoop; keeping both waits here avoids a
    /// Swift-concurrency continuation during the bridge's final close.
    @_spi(GitKitSSH)
    public func closeSynchronously() throws {
        precondition(!self.channel.eventLoop.inEventLoop, "SSHClient.closeSynchronously() must not run on an EventLoop")
        guard self.beginClose() else { return }
        do {
            try self.channel.close().wait()
        } catch ChannelError.alreadyClosed {
            // The peer or authentication-exhaustion workaround already closed it.
        }
        let shutdownComplete = DispatchSemaphore(value: 0)
        self.eventLoopGroup.shutdownGracefully(queue: Self.shutdownQueue) { error in
            self.lifecycleLock.lock()
            self.synchronousShutdownError = error
            self.lifecycleLock.unlock()
            shutdownComplete.signal()
        }
        shutdownComplete.wait()
        self.lifecycleLock.lock()
        let shutdownError = self.synchronousShutdownError
        self.lifecycleLock.unlock()
        if let shutdownError {
            throw shutdownError
        }
    }

    private func beginClose() -> Bool {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        guard !self.closeStarted else { return false }
        self.closeStarted = true
        return true
    }

    /// NIO's convenience async shutdown overload delivers through the global dispatch queue,
    /// which may itself be occupied by cooperative-pool workers. Use an independent serial queue
    /// so both ordinary async teardown and GitKitSSH's saturated-pool path can make progress.
    private static func shutdown(_ group: EventLoopGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully(queue: Self.shutdownQueue) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
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
