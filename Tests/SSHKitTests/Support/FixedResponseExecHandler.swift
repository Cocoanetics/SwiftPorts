import NIOCore
import NIOSSH

/// Responds to any exec request with a fixed stdout/stderr/exit-status triple — see the type doc
/// on `InProcessSSHServer`.
final class FixedResponseExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let execRequest = event as? SSHChannelRequestEvent.ExecRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }

        let channel = context.channel
        var stdout = channel.allocator.buffer(capacity: 64)
        stdout.writeString("ran: \(execRequest.command)\n")
        var stderr = channel.allocator.buffer(capacity: 16)
        stderr.writeString("note\n")

        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(stdout)), promise: nil)
        channel.writeAndFlush(SSHChannelData(type: .stdErr, data: .byteBuffer(stderr)), promise: nil)
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
