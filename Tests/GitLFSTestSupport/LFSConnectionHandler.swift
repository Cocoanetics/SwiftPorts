import Foundation
import NIOCore
import NIOHTTP1

/// One HTTP/1.1 connection. Shared objects, faults, and the request log live on `LFSServerCore`.
final class LFSConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let core: LFSServerCore
    private var head: HTTPRequestHead?
    private var body = Data()

    init(core: LFSServerCore) {
        self.core = core
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            head = request
            body.removeAll(keepingCapacity: true)
            if expectsContinue(request) {
                writeContinue(context: context, version: request.version)
            }
        case .body(let buffer):
            body.append(contentsOf: buffer.readableBytesView)
        case .end:
            guard let request = head else { return }
            head = nil
            let payload = body
            body.removeAll(keepingCapacity: true)
            respond(request, body: payload, context: context)
        }
    }

    /// Later object transfers under an overlap hold stay unanswered until enough
    /// of them are in flight. The first object transfer is answered immediately
    /// because the queue does not start its other workers until that one succeeds.
    private func respond(_ request: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        let method = request.method.rawValue
        let uri = request.uri
        let headers = lowercase(request.headers)
        guard core.beginObjectHold(method: method, uri: uri) == .hold else {
            write(core.handle(method: method, uri: uri, headers: headers, body: body), context: context,
                  version: request.version)
            return
        }
        let response = core.handle(method: method, uri: uri, headers: headers, body: body, record: false)
        let promise = context.eventLoop.makePromise(of: Void.self)
        let boundContext = context.loopBound
        let version = request.version
        let serverCore = core
        promise.futureResult.whenComplete { _ in
            let context = boundContext.value
            guard let handler = context.handler as? LFSConnectionHandler else { return }
            handler.write(response, context: context, version: version)
            serverCore.record(method: method, uri: uri, headers: headers, body: body, response: response)
        }
        serverCore.parkObjectHold(promise, method: method, uri: uri, body: body)
    }

    private func expectsContinue(_ request: HTTPRequestHead) -> Bool {
        request.headers["expect"].contains { value in
            value.range(of: "100-continue", options: .caseInsensitive) != nil
        }
    }

    /// Informational head only. An `.end` here would finish the response, and the real status
    /// would then be rejected by `HTTPServerPipelineHandler`.
    private func writeContinue(context: ChannelHandlerContext, version: HTTPVersion) {
        let response = HTTPResponseHead(version: version, status: .continue)
        context.writeAndFlush(wrapOutboundOut(.head(response)), promise: nil)
    }

    private func lowercase(_ headers: HTTPHeaders) -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in headers {
            fields[name.lowercased()] = value
        }
        return fields
    }

    private func write(_ response: LFSWireResponse, context: ChannelHandlerContext, version: HTTPVersion) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        let responseHead = HTTPResponseHead(
            version: version,
            status: HTTPResponseStatus(statusCode: response.status),
            headers: headers
        )
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        if !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
