import NIOCore
import NIOSSH

/// Bridges one SSH exec child channel's inbound events to `SSHExecChannel`'s async streams and
/// exit-status promise. Mirrors `swift-nio-ssh`'s own `NIOSSHClient` example
/// (`Sources/NIOSSHClient/ExecHandler.swift`), but yields to `AsyncStream`s instead of writing to
/// the real process stdout/stderr file descriptors.
final class SSHExecChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let stdoutContinuation: AsyncStream<[UInt8]>.Continuation
    private let stderrContinuation: AsyncStream<[UInt8]>.Continuation
    private let exitStatusPromise: EventLoopPromise<Int32>

    /// Settled by the next `ChannelSuccessEvent`/`ChannelFailureEvent` this channel sees — used
    /// only for `pty-req`, the one channel request this port sends with `wantReply: true`
    /// (`client_session2_setup`, `clientloop.c`). Must only be mutated on this channel's
    /// `EventLoop` (see `SSHClient.requestPseudoTerminal`).
    private var pendingReplyPromise: EventLoopPromise<Bool>?

    init(
        stdoutContinuation: AsyncStream<[UInt8]>.Continuation,
        stderrContinuation: AsyncStream<[UInt8]>.Continuation,
        exitStatusPromise: EventLoopPromise<Int32>
    ) {
        self.stdoutContinuation = stdoutContinuation
        self.stderrContinuation = stderrContinuation
        self.exitStatusPromise = exitStatusPromise
    }

    /// Arms `pendingReplyPromise` for the next channel-request reply. Must be called on this
    /// channel's `EventLoop`.
    func expectReply(_ promise: EventLoopPromise<Bool>) {
        self.pendingReplyPromise = promise
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
        } else if event is ChannelSuccessEvent {
            self.pendingReplyPromise?.succeed(true)
            self.pendingReplyPromise = nil
        } else if event is ChannelFailureEvent {
            self.pendingReplyPromise?.succeed(false)
            self.pendingReplyPromise = nil
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.stdoutContinuation.finish()
        self.stderrContinuation.finish()
        self.exitStatusPromise.fail(ChannelError.alreadyClosed)
        self.pendingReplyPromise?.fail(ChannelError.alreadyClosed)
        self.pendingReplyPromise = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
