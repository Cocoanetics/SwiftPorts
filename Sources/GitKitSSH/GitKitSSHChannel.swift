import GitKit
import SSHKit

/// Bridges one SSHKit exec channel to GitKit's synchronous
/// ``GitSSHChannel`` contract. libgit2 calls `read`/`write`/`close`
/// serially, from a single thread, for the lifetime of one connection
/// (see `SSHSubtransportContext` in GitKit's `SSHTransportBridge.swift`)
/// — so the unsynchronized mutable state below (`pendingStdout`, the
/// stdout iterator) is safe despite not being statically `Sendable`.
final class GitKitSSHChannel: GitSSHChannel, @unchecked Sendable {
    private let client: SSHClient
    private let exec: SSHExecChannel
    private var stdoutIterator: AsyncStream<[UInt8]>.Iterator
    private var pendingStdout: [UInt8] = []
    private let stderrCollector: GitKitSSHStderrCollector

    init(client: SSHClient, exec: SSHExecChannel) {
        self.client = client
        self.exec = exec
        self.stdoutIterator = exec.stdout.makeAsyncIterator()
        self.stderrCollector = GitKitSSHStderrCollector(stream: exec.stderr)
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }

        // `AsyncStream`'s producer side could in principle yield an empty
        // chunk; skip over it rather than treating it as EOF (`nil` is
        // the only true end-of-stream signal).
        while pendingStdout.isEmpty {
            guard let chunk = try GitKitSSHBridge.runBlocking({ await self.stdoutIterator.next() }) else {
                try GitKitSSHBridge.runBlocking { try await self.failIfRemoteCommandFailed() }
                return 0
            }
            pendingStdout = chunk
        }

        let n = min(pendingStdout.count, buffer.count)
        pendingStdout.withUnsafeBufferPointer { source in
            base.copyMemory(from: source.baseAddress!, byteCount: n)
        }
        pendingStdout.removeFirst(n)
        return n
    }

    func write(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return }
        let bytes = [UInt8](UnsafeRawBufferPointer(start: base, count: buffer.count))
        try GitKitSSHBridge.runBlocking { try await self.exec.write(bytes) }
    }

    func close() {
        _ = try? GitKitSSHBridge.runBlocking { () async throws -> Void in
            try? await self.exec.closeStdin()
            try await self.client.close()
        }
    }

    /// Called once `stdout` hits EOF. The exit status and any stderr the
    /// remote wrote are both only meaningful once the channel has gone
    /// fully inactive — which is also when `stdout`'s stream finishes
    /// (`SSHExecChannelHandler.channelInactive` fires the exit-status
    /// event before it finishes both streams) — so this is the first
    /// point either can be read reliably. A non-zero exit throws,
    /// surfacing the remote's actual diagnostic (e.g. "repository not
    /// found") through GitKit's error path instead of the generic
    /// EOF/protocol failure libgit2 would otherwise report.
    private func failIfRemoteCommandFailed() async throws {
        let status = (try? await exec.exitStatus) ?? 0
        guard status != 0 else { return }
        let stderrText = await stderrCollector.waitAndDrain()
        throw GitKitSSHRemoteCommandError(exitStatus: status, stderrText: stderrText)
    }
}
