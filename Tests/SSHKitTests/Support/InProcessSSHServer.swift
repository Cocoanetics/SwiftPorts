import NIOCore
import NIOPosix
import NIOSSH

/// A minimal, pure-`NIOSSH` server role — no system `sshd`, no `Process` — so `SSHClient`'s
/// protocol-level plumbing (KEX, host-key exchange, public-key user auth, exec channels) can be
/// exercised on every CI platform, including ones that can't spawn a subprocess (Windows, iOS,
/// Android), per the test plan in issue #112/#111.
///
/// The exec handler doesn't run a real shell: it writes a fixed line echoing the requested command
/// back on stdout, a fixed line on stderr, and a fixed exit status, which is enough to prove the
/// client-side channel plumbing end-to-end without depending on a host shell.
final class InProcessSSHServer: @unchecked Sendable {
    let hostKey: NIOSSHPrivateKey
    private let group: EventLoopGroup
    private let channel: Channel

    private init(hostKey: NIOSSHPrivateKey, group: EventLoopGroup, channel: Channel) {
        self.hostKey = hostKey
        self.group = group
        self.channel = channel
    }

    var port: Int {
        self.channel.localAddress?.port ?? 0
    }

    static func start(authentication: AuthenticationPolicy) async throws -> InProcessSSHServer {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(
                            role: .server(
                                .init(
                                    hostKeys: [hostKey],
                                    userAuthDelegate: ServerAuthenticationDelegate(policy: authentication)
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: { childChannel, channelType in
                                guard case .session = channelType else {
                                    return childChannel.eventLoop.makeFailedFuture(InProcessSSHServerError.unsupportedChannelType)
                                }
                                return childChannel.eventLoop.makeCompletedFuture {
                                    try childChannel.pipeline.syncOperations.addHandler(FixedResponseExecHandler())
                                }
                            }
                        )
                    )
                }
            }

        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return InProcessSSHServer(hostKey: hostKey, group: group, channel: channel)
    }

    func shutdown() async throws {
        try await self.channel.close().get()
        try await self.group.shutdownGracefully()
    }

    enum AuthenticationPolicy {
        case acceptAnyPublicKey
        case rejectAll
    }
}
