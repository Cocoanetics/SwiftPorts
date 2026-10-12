import NIOCore
import NIOSSH

/// Accumulates stdin and, once the client signals EOF (`closeStdin()` — an SSH channel EOF, which
/// `SSHChildChannel` surfaces as `ChannelEvent.inputClosed`), echoes it back on stdout, sends exit
/// status 0, and closes. Deterministic by construction: unlike `FixedResponseExecHandler`, it never
/// responds before the client has finished writing, so it's safe for tests that exercise
/// `SSHExecChannel.write`/`closeStdin` without racing the server's own close.
final class EchoStdinExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private var receivedStdin: [UInt8] = []

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)
        guard case .byteBuffer(let bytes) = data.data, data.type == .channel else {
            return
        }
        self.receivedStdin.append(contentsOf: bytes.readableBytesView)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard case ChannelEvent.inputClosed = event else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        let channel = context.channel
        var stdout = channel.allocator.buffer(capacity: self.receivedStdin.count)
        stdout.writeBytes(self.receivedStdin)

        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(stdout)), promise: nil)
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
