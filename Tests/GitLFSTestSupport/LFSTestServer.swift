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
/// ``holdObjectTransfers(untilInFlight:timeout:)`` keeps later object `GET` and
/// `PUT` responses unfinished until that many of them are in flight. The first
/// object transfer is answered immediately. Batch and verify requests are not held.
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

    /// Serve one smart-HTTP branch advertisement, gated by this Authorization header.
    public func advertiseGitHead(_ oid: String, authorization: String) {
        core.advertiseGitHead(oid, authorization: authorization)
    }

    /// Keep object `GET` and `PUT` responses unfinished until `count` of them
    /// are in flight together. The first object transfer is answered in full,
    /// because a transfer queue does not start its other workers until that
    /// response has succeeded; the requests those workers then send are the
    /// ones that have to overlap. Batch and verify requests are not held.
    /// Held responses are sent once `count` later object transfers overlap.
    /// If they never do, the hold ends at `timeout` and a serial queue still
    /// finishes. ``peakObjectTransfers()`` is the most of those later object
    /// transfers in flight at once since this call.
    public func holdObjectTransfers(untilInFlight count: Int, timeout: Duration = .seconds(10)) async {
        let amount = Self.timeAmount(timeout)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.channel.eventLoop.execute {
                self.core.armObjectHold(count: count, timeout: amount, loop: self.channel.eventLoop)
                continuation.resume()
            }
        }
    }

    /// Most object `GET`/`PUT` requests open at once since the last
    /// ``holdObjectTransfers(untilInFlight:timeout:)``.
    public func peakObjectTransfers() async -> Int {
        await withCheckedContinuation { continuation in
            self.channel.eventLoop.execute {
                continuation.resume(returning: self.core.peakObjectTransfers())
            }
        }
    }

    /// Close the listening socket and stop the event-loop threads.
    public func shutdown() async {
        guard claimShutdown() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.channel.eventLoop.execute {
                self.core.releaseObjectHold()
                continuation.resume()
            }
        }
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }

    deinit {
        guard claimShutdown() else { return }
        try? group.syncShutdownGracefully()
    }

    private static func timeAmount(_ duration: Duration) -> TimeAmount {
        let components = duration.components
        let nanoseconds = components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
        return .nanoseconds(nanoseconds)
    }

    private func claimShutdown() -> Bool {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }
        if didShutdown { return false }
        didShutdown = true
        return true
    }
}
