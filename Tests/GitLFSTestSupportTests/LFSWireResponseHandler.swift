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
    private let continued: EventLoopPromise<Void>?
    private var value = WireBody(status: 0, headers: [:], body: Data())

    init(response: EventLoopPromise<WireBody>, continued: EventLoopPromise<Void>? = nil) {
        self.response = response
        self.continued = continued
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            value.status = Int(head.status.code)
            if head.status.code == 100 { continued?.succeed(()) }
            else if head.status.code >= 200 { continued?.fail(URLError(.badServerResponse)) }
            for (name, text) in head.headers { value.headers[name.lowercased()] = text }
        case .body(let buffer):
            value.body.append(contentsOf: buffer.readableBytesView)
        case .end:
            if value.status >= 200 { response.succeed(value) }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continued?.fail(error)
        response.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continued?.fail(URLError(.networkConnectionLost))
        response.fail(URLError(.networkConnectionLost))
        context.fireChannelInactive()
    }
}
