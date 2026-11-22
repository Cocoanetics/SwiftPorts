import Foundation
import NIOCore
import NIOPosix

/// Accepts one connection, reads its first bytes, then never reads again.
///
/// A large request body fills the socket buffers, so the client stays inside a
/// pending body write. A test can then cancel it there every time (issue #273).
final class StalledWireServer: @unchecked Sendable {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let firstRead: EventLoopPromise<Void>
    private var channel: Channel?

    private init() {
        firstRead = group.next().makePromise(of: Void.self)
    }

    static func withServer<T: Sendable>(_ body: (StalledWireServer) async throws -> T) async throws -> T {
        let server = StalledWireServer()
        do {
            try await server.start()
            let value = try await body(server)
            await server.shutdown()
            return value
        } catch {
            await server.shutdown()
            throw error
        }
    }

    var endpoint: String {
        "http://127.0.0.1:\(channel?.localAddress?.port ?? 0)"
    }

    /// Resolves once the request head has reached the server.
    func requestStarted() async throws {
        try await firstRead.futureResult.get()
    }

    private func start() async throws {
        let firstRead = firstRead
        channel = try await ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(StalledReadHandler(firstRead: firstRead))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    private func shutdown() async {
        firstRead.fail(ChannelError.ioOnClosedChannel)
        try? await channel?.close().get()
        try? await group.shutdownGracefully()
    }
}

private final class StalledReadHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let firstRead: EventLoopPromise<Void>

    init(firstRead: EventLoopPromise<Void>) {
        self.firstRead = firstRead
    }

    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        firstRead.succeed(())
    }
}
