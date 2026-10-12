import NIOCore
import NIOSSH

/// A running remote command: async byte streams for stdout/stderr, a writer for stdin, and the
/// exit status once the remote command finishes. Backs `ssh host command` (`SSHCommand`/`ssh`
/// land in #114) and the GitKit SSH transport (#113).
public final class SSHExecChannel: @unchecked Sendable {
    private let channel: Channel
    private let exitStatusPromise: EventLoopPromise<Int32>

    /// Bytes from the remote command's stdout.
    public let stdout: AsyncStream<[UInt8]>

    /// Bytes from the remote command's stderr.
    public let stderr: AsyncStream<[UInt8]>

    init(channel: Channel, stdout: AsyncStream<[UInt8]>, stderr: AsyncStream<[UInt8]>, exitStatusPromise: EventLoopPromise<Int32>) {
        self.channel = channel
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatusPromise = exitStatusPromise
    }

    /// Writes to the remote command's stdin.
    public func write(_ bytes: [UInt8]) async throws {
        var buffer = self.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await self.channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    /// Half-closes stdin (sends EOF), the way closing the write end of `ssh`'s stdin does.
    public func closeStdin() async throws {
        try await self.channel.close(mode: .output).get()
    }

    /// Suspends until the remote command exits, then returns its exit status.
    public var exitStatus: Int32 {
        get async throws {
            try await self.exitStatusPromise.futureResult.get()
        }
    }

    /// Suspends until the channel has fully closed (after stdout/stderr finish and the exit
    /// status is known).
    public func waitUntilClosed() async throws {
        try await self.channel.closeFuture.get()
    }
}

/// Bridges one SSH exec child channel's inbound events to `SSHExecChannel`'s async streams and
/// exit-status promise. Mirrors `swift-nio-ssh`'s own `NIOSSHClient` example
/// (`Sources/NIOSSHClient/ExecHandler.swift`), but yields to `AsyncStream`s instead of writing to
/// the real process stdout/stderr file descriptors.
final class SSHExecChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let stdoutContinuation: AsyncStream<[UInt8]>.Continuation
    private let stderrContinuation: AsyncStream<[UInt8]>.Continuation
    private let exitStatusPromise: EventLoopPromise<Int32>

    init(
        stdoutContinuation: AsyncStream<[UInt8]>.Continuation,
        stderrContinuation: AsyncStream<[UInt8]>.Continuation,
        exitStatusPromise: EventLoopPromise<Int32>
    ) {
        self.stdoutContinuation = stdoutContinuation
        self.stderrContinuation = stderrContinuation
        self.exitStatusPromise = exitStatusPromise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = data.data else {
            return
        }

        switch data.type {
        case .channel:
            self.stdoutContinuation.yield(Array(bytes.readableBytesView))
        case .stdErr:
            self.stderrContinuation.yield(Array(bytes.readableBytesView))
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exitStatus = event as? SSHChannelRequestEvent.ExitStatus {
            self.exitStatusPromise.succeed(Int32(exitStatus.exitStatus))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.stdoutContinuation.finish()
        self.stderrContinuation.finish()
        self.exitStatusPromise.fail(ChannelError.alreadyClosed)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
