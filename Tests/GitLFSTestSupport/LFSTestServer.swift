import Foundation
import NIOCore
import NIOPosix

/// Why ``LFSTestServer/start()`` could not bind.
public enum LFSTestServerError: Error, Equatable {
    case missingPort
}

/// In-process Git LFS basic-transfer server.
///
/// Binds `127.0.0.1` on an ephemeral port. `POST /objects/batch` speaks
/// `application/vnd.git-lfs+json`. Download actions are `GET`, upload actions
/// are `PUT`, and verify actions are `POST` of `{"oid","size"}`. Verify
/// returns 200 only when the stored bytes hash to that oid and have that size.
/// A digest mismatch removes those bytes; ``store(_:oid:)`` is what marks an
/// object as already present.
/// ``requests()`` records every response. ``inject(_:)`` arms the faults a
/// transfer suite needs: 401, per-object 404 / 410 / 422, 429 with `Retry-After`,
/// 5xx, a 5xx that stays armed, an already-past `expires_at`, and a body whose
/// size or SHA-256 is wrong.
/// An object passed to ``store(_:oid:)`` is a batch object with no `upload` action.
public final class LFSTestServer: @unchecked Sendable {
    /// LFS API root, `http://127.0.0.1:<port>`. Clients POST `<endpoint>/objects/batch`.
    public let endpoint: URL

    public var port: Int { endpoint.port ?? 0 }

    private let core: LFSServerCore
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let shutdownLock = NSLock()
    private var didShutdown = false

    private init(
        endpoint: URL, core: LFSServerCore, group: MultiThreadedEventLoopGroup, channel: Channel
    ) {
        self.endpoint = endpoint
        self.core = core
        self.group = group
        self.channel = channel
    }

    /// Bind `127.0.0.1` on an ephemeral port and serve until ``shutdown()``.
    public static func start() async throws -> LFSTestServer {
        let core = LFSServerCore()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(LFSConnectionHandler(core: core))
                }
            }
        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        guard let port = channel.localAddress?.port, port > 0,
              let endpoint = URL(string: "http://127.0.0.1:\(port)") else {
            try? await channel.close().get()
            try? await group.shutdownGracefully()
            throw LFSTestServerError.missingPort
        }
        core.setEndpoint(endpoint)
        return LFSTestServer(endpoint: endpoint, core: core, group: group, channel: channel)
    }

    /// Start a server, run `body`, then shut the server down.
    public static func withServer<T: Sendable>(
        _ body: (LFSTestServer) async throws -> T
    ) async throws -> T {
        let server = try await start()
        do {
            let value = try await body(server)
            await server.shutdown()
            return value
        } catch {
            await server.shutdown()
            throw error
        }
    }

    /// Keeps `bytes` under `oid`. An upload batch for this id has no `upload` action.
    public func store(_ bytes: Data, oid: String) {
        core.store(bytes, oid: oid)
    }

    /// Bytes stored for `oid`, including a successful `PUT`.
    public func bytes(for oid: String) -> Data? {
        core.bytes(for: oid)
    }

    /// Arms one fault. A status fault replaces a pending status fault.
    /// An object fault replaces a fault already armed for that object id.
    public func inject(_ fault: LFSTestFault) {
        core.inject(fault)
    }

    /// Responses so far, in the order the server finished them.
    public func requests() -> [LFSRecordedRequest] {
        core.requests()
    }

    /// Close the listening socket and stop the event-loop threads.
    public func shutdown() async {
        guard claimShutdown() else { return }
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    deinit {
        guard claimShutdown() else { return }
        try? group.syncShutdownGracefully()
    }

    private func claimShutdown() -> Bool {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        if didShutdown { return false }
        didShutdown = true
        return true
    }
}
