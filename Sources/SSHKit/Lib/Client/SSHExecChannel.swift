import NIOCore
import NIOSSH

/// A running remote command: async byte streams for stdout/stderr, a writer for stdin, and the
/// exit status once the remote command finishes. Backs `ssh host command` (`SSHCommand`/`ssh`
/// land in #114) and the GitKit SSH transport (#113).
public final class SSHExecChannel: @unchecked Sendable {
    private let channel: Channel
    private let exitStatusPromise: EventLoopPromise<Int32>

    /// Bytes from the remote command's stdout.
    public let stdout: AsyncStream<[UInt8]>

    /// Bytes from the remote command's stderr.
    public let stderr: AsyncStream<[UInt8]>

    /// Whether `SSHClient.exec(_:pseudoTerminal:)`/`shell(pseudoTerminal:)` successfully allocated
    /// a PTY on this channel — `false` for a plain exec channel, and also `false` when an
    /// automatically (not `-t`) requested PTY was rejected by the peer (see `requestPseudoTerminal`
    /// in `SSHClient`).
    public let hasPseudoTerminal: Bool

    init(
        channel: Channel,
        stdout: AsyncStream<[UInt8]>,
        stderr: AsyncStream<[UInt8]>,
        exitStatusPromise: EventLoopPromise<Int32>,
        hasPseudoTerminal: Bool = false
    ) {
        self.channel = channel
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatusPromise = exitStatusPromise
        self.hasPseudoTerminal = hasPseudoTerminal
    }

    /// Writes to the remote command's stdin.
    public func write(_ bytes: [UInt8]) async throws {
        var buffer = self.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await self.channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).get()
    }

    /// Half-closes stdin (sends EOF), the way closing the write end of `ssh`'s stdin does.
    public func closeStdin() async throws {
        try await self.channel.close(mode: .output).get()
    }

    /// Notifies the peer of a local terminal resize (RFC 4254 §6.7, `window-change`) — only
    /// meaningful on a channel with an allocated PTY. Mirrors `channel_send_window_changes()`,
    /// sent from `client_check_window_change()`'s `SIGWINCH` poll (`clientloop.c`). `wantReply` is
    /// always false for this request, matching OpenSSH.
    public func sendWindowChange(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async throws {
        try await self.channel.triggerUserOutboundEvent(
            SSHChannelRequestEvent.WindowChangeRequest(
                terminalCharacterWidth: columns,
                terminalRowHeight: rows,
                terminalPixelWidth: pixelWidth,
                terminalPixelHeight: pixelHeight)
        ).get()
    }

    /// Suspends until the remote command exits, then returns its exit status.
    public var exitStatus: Int32 {
        get async throws {
            try await self.exitStatusPromise.futureResult.get()
        }
    }

    /// Suspends until the channel has fully closed (after stdout/stderr finish and the exit
    /// status is known).
    public func waitUntilClosed() async throws {
        try await self.channel.closeFuture.get()
    }
}
