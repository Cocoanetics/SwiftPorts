import Foundation

/// Drains one exec channel's stderr concurrently with
/// ``GitKitSSHChannel/read(into:)`` consuming stdout, so the remote's own
/// diagnostic (e.g. "repository not found") is already in hand if the
/// command later turns out to have failed — libgit2 never asks for stderr
/// itself, only for stdout and the eventual EOF/error.
///
/// Filled only by the background drain `Task`, read only after
/// ``waitAndDrain()`` awaits that task to completion (which happens once
/// SSHKit's channel goes `channelInactive` and finishes the stream) — so
/// the lock below only ever guards against that one handoff, never a
/// genuine race.
final class GitKitSSHStderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var drainTask: Task<Void, Never>?

    init(stream: AsyncStream<[UInt8]>) {
        // Every other stored property already has its default value at this
        // point; only the explicit assignment below (rather than a closure
        // passed as `drainTask`'s own initial value) lets it capture `self`.
        self.drainTask = Task { [weak self] in
            for await chunk in stream {
                self?.append(chunk)
            }
        }
    }

    private func append(_ chunk: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(contentsOf: chunk)
    }

    /// Waits for stderr to finish draining, then returns everything
    /// collected so far, decoded leniently as UTF-8 and trimmed — the way
    /// a terminal would display the remote command's error output.
    func waitAndDrain() async -> String {
        await drainTask?.value
        return snapshot()
    }

    /// Plain synchronous accessor so the locking happens outside any
    /// `async` function body — `NSLock.lock()`/`unlock()` are themselves
    /// unavailable from an async context.
    private func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
