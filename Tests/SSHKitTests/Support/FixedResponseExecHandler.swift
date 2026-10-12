import NIOCore
import NIOSSH

/// Responds to any exec or shell request with a fixed stdout/stderr/exit-status triple — see the
/// type doc on `InProcessSSHServer`. Also answers a `pty-req`, either accepting or rejecting it
/// per `acceptsPseudoTerminal`, the way a real `sshd` replies `SSH_MSG_CHANNEL_SUCCESS`/`_FAILURE`.
final class FixedResponseExecHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let acceptsPseudoTerminal: Bool

    init(acceptsPseudoTerminal: Bool = true) {
        self.acceptsPseudoTerminal = acceptsPseudoTerminal
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).assumeIsolated().whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let execRequest as SSHChannelRequestEvent.ExecRequest:
            self.respond(on: context.channel, label: "ran: \(execRequest.command)")
        case is SSHChannelRequestEvent.ShellRequest:
            self.respond(on: context.channel, label: "shell")
        case let ptyRequest as SSHChannelRequestEvent.PseudoTerminalRequest:
            guard ptyRequest.wantReply else { return }
            if self.acceptsPseudoTerminal {
                context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
            } else {
                context.channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil)
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    private func respond(on channel: Channel, label: String) {
        var stdout = channel.allocator.buffer(capacity: 64)
        stdout.writeString("\(label)\n")
        var stderr = channel.allocator.buffer(capacity: 16)
        stderr.writeString("note\n")

        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(stdout)), promise: nil)
        channel.writeAndFlush(SSHChannelData(type: .stdErr, data: .byteBuffer(stderr)), promise: nil)
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
