import Foundation
import NIOCore
import NIOHTTP1
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Collects one response. The caller closes and awaits the channel before returning it.
final class LFSWireResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let response: EventLoopPromise<WireBody>
    private var value = WireBody(status: 0, headers: [:], body: Data())

    init(response: EventLoopPromise<WireBody>) {
        self.response = response
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            value.status = Int(head.status.code)
            for (name, text) in head.headers { value.headers[name.lowercased()] = text }
        case .body(let buffer):
            value.body.append(contentsOf: buffer.readableBytesView)
        case .end:
            response.succeed(value)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        response.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        response.fail(URLError(.networkConnectionLost))
        context.fireChannelInactive()
    }
}
