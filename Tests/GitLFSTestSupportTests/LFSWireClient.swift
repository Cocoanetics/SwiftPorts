import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing
import GitLFSTestSupport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct WireBody: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data

    func value(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

struct BatchDocument: Decodable, Sendable {
    var transfer: String
    var objects: [BatchObject]

    func object(_ oid: String) -> BatchObject? {
        objects.first { $0.oid == oid }
    }
}

struct BatchObject: Decodable, Sendable {
    var oid: String
    var size: Int
    var actions: [String: BatchAction]?
    var error: BatchErrorBody?
}

struct BatchAction: Decodable, Sendable {
    var href: String
    var header: [String: String]
    var expiresAt: String

    enum CodingKeys: String, CodingKey {
        case href
        case header
        case expiresAt = "expires_at"
    }
}

struct BatchErrorBody: Decodable, Sendable {
    var code: Int
    var message: String
}

struct ErrorEnvelope: Decodable {
    var message: String
}

final class LFSWireClient: @unchecked Sendable {
    static let mediaType = "application/vnd.git-lfs+json"

    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var stopped = false

    private init() {}

    var isShutdown: Bool { lock.withLock { stopped } }

    var openConnectionCount: Int {
        lock.withLock { channels.count }
    }

    /// FoundationNetworking's session invalidation callback does not drain curl's
    /// dispatch socket sources. Use NIO for these server probes so socket closure
    /// is awaited explicitly, including on Windows (issue #240).
    static func withServer<T: Sendable>(
        _ body: (LFSTestServer, LFSWireClient) async throws -> T
    ) async throws -> T {
        try await LFSTestServer.withServer { server in
            let client = LFSWireClient()
            do {
                let value = try await body(server, client)
                await client.shutdown()
                return value
            } catch {
                await client.shutdown()
                throw error
            }
        }
    }

    private func shutdown() async {
        let connections = lock.withLock { Array(channels.values) }
        for channel in connections {
            try? await channel.close().get()
            try? await channel.closeFuture.get()
        }
        try? await group.shutdownGracefully()
        lock.withLock { stopped = true }
    }

    func postBatch(
        _ server: LFSTestServer, operation: String, objects: [(oid: String, size: Int)]
    ) async throws -> WireBody {
        let payload = BatchPost(
            operation: operation,
            objects: objects.map { ObjectPost(oid: $0.oid, size: $0.size) }
        )
        let url = try Self.url(server, "/objects/batch")
        return try await send(url, method: .POST, body: try Self.encode(payload), json: true)
    }

    static func document(_ response: WireBody) throws -> BatchDocument {
        try JSONDecoder().decode(BatchDocument.self, from: response.body)
    }

    func get(_ href: String) async throws -> WireBody {
        let url = try #require(URL(string: href))
        return try await send(url, method: .GET, body: nil, json: false)
    }

    func put(_ href: String, body: Data, expectContinue: Bool = false, chunked: Bool = false) async throws -> WireBody {
        let url = try #require(URL(string: href))
        return try await send(url, method: .PUT, body: body, json: false,
                              expectContinue: expectContinue, chunked: chunked)
    }

    func verify(_ href: String, oid: String, size: Int) async throws -> WireBody {
        let url = try #require(URL(string: href))
        let payload = VerifyPost(oid: oid, size: size)
        return try await send(url, method: .POST, body: try Self.encode(payload), json: true)
    }

    private static func url(_ server: LFSTestServer, _ path: String) throws -> URL {
        try #require(URL(string: server.endpoint.absoluteString + path))
    }

    private func send(
        _ url: URL, method: HTTPMethod, body: Data?, json: Bool,
        expectContinue: Bool = false, chunked: Bool = false
    ) async throws -> WireBody {
        let host = try #require(url.host)
        let port = try #require(url.port)
        let loop = group.next()
        let response = loop.makePromise(of: WireBody.self)
        let continued = expectContinue ? loop.makePromise(of: Void.self) : nil
        let channel: Channel
        do {
            let bootstrap = ClientBootstrap(group: loop)
                .connectTimeout(.seconds(10))
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        // The convenience setup drops 1xx responses. This probe
                        // must observe 100 before it is allowed to send a body.
                        try channel.pipeline.syncOperations.addHandlers([
                            HTTPRequestEncoder(),
                            ByteToMessageHandler(HTTPResponseDecoder(
                                leftOverBytesStrategy: .dropBytes, informationalResponseStrategy: .forward)),
                            NIOHTTPRequestHeadersValidator()
                        ])
                        try channel.pipeline.syncOperations.addHandler(
                            LFSWireResponseHandler(response: response, continued: continued))
                    }
                }
            #if os(Windows)
            // Avoid swift-nio 2.105.0's Windows.recv WSAEWOULDBLOCK throw on a
            // second speculative read in the same WSAPoll readiness turn.
            _ = bootstrap.channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            #endif
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            continued?.fail(error)
            response.fail(error)
            throw error
        }
        let identifier = ObjectIdentifier(channel)
        lock.withLock { channels[identifier] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.channels.removeValue(forKey: identifier) }
        }
        let timeout = loop.scheduleTask(in: .seconds(10)) {
            continued?.fail(URLError(.timedOut))
            response.fail(URLError(.timedOut))
            channel.close(promise: nil)
        }
        do {
            let value = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await channel.writeAndFlush(Self.request(
                    url, method: method, body: body, json: json,
                    expectContinue: expectContinue, chunked: chunked)).get()
                if let continued { try await continued.futureResult.get() }
                if let body {
                    for offset in stride(from: 0, to: body.count, by: 32 * 1024) {
                        let end = min(offset + 32 * 1024, body.count)
                        var buffer = channel.allocator.buffer(capacity: end - offset)
                        buffer.writeBytes(body[offset..<end])
                        try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer))).get()
                    }
                }
                try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
                return try await response.futureResult.get()
            } onCancel: {
                continued?.fail(CancellationError())
                response.fail(CancellationError())
                channel.close(promise: nil)
            }
            timeout.cancel()
            try? await channel.close().get()
            try await channel.closeFuture.get()
            return value
        } catch {
            response.fail(error)
            timeout.cancel()
            try? await channel.close().get()
            try? await channel.closeFuture.get()
            throw error
        }
    }

    private static func request(
        _ url: URL, method: HTTPMethod, body: Data?, json: Bool, expectContinue: Bool, chunked: Bool
    ) -> HTTPClientRequestPart {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "\(url.host ?? "127.0.0.1"):\(url.port ?? 80)")
        if chunked { headers.add(name: "Transfer-Encoding", value: "chunked") }
        else { headers.add(name: "Content-Length", value: String(body?.count ?? 0)) }
        if expectContinue { headers.add(name: "Expect", value: "100-continue") }
        if json {
            headers.add(name: "Accept", value: mediaType)
            headers.add(name: "Content-Type", value: mediaType)
        } else if method == .PUT {
            headers.add(name: "Content-Type", value: "application/octet-stream")
        }
        let uri = url.path + (url.query.map { "?" + $0 } ?? "")
        return .head(HTTPRequestHead(version: .http1_1, method: method, uri: uri, headers: headers))
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

private struct BatchPost: Encodable {
    var operation: String
    var transfers = ["basic"]
    var objects: [ObjectPost]
}

private struct ObjectPost: Encodable {
    var oid: String
    var size: Int
}

private struct VerifyPost: Encodable {
    var oid: String
    var size: Int
}
