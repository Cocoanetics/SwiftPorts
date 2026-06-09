import Foundation
import ShellKit
import libgit2

/// Formats and emits `remote: …` / `Receiving objects: …` /
/// `From <url>` / `<oldsha>..<newsha> <ref> -> <tracking>` lines to
/// stderr. Mirrors what real git prints during fetch / clone / push.
///
/// Each network-op (`fetch`/`clone`/`push`) builds one of these,
/// passes it through `withCallbacksPayload` to install C trampolines on
/// `git_remote_callbacks`, and the trampolines mutate it via the
/// shared `payload` raw pointer.
struct ProgressReporter {
    /// `From <url>` / `To <url>` header — emitted lazily, exactly once,
    /// just before the first per-ref summary line.
    var headerURL: String?
    var headerEmitted = false
    /// `From` (fetch) vs `To` (push) — the header verb.
    let direction: Direction

    enum Direction { case fetch, push }

    /// Pending per-ref summary lines. We collect them inside the
    /// callbacks (which fire mid-operation) and flush them in the
    /// caller's `defer` so output isn't interleaved with transfer
    /// progress. Real git does the same.
    var refLines: [String] = []

    /// `Receiving objects:` / `Writing objects:` last printed percent.
    /// Only re-emit when the integer percent advances, to match real
    /// git's roughly-100-updates-per-phase pacing.
    var lastTransferPct: Int = -1
    /// Same throttle for `Resolving deltas:`.
    var lastDeltaPct: Int = -1

    /// Sideband state: whether we're currently in the middle of a line
    /// (i.e. saw text but no terminator yet) so the next chunk doesn't
    /// re-prepend `remote: `. Set when the previous chunk ended without
    /// `\r` or `\n`.
    var sidebandLineOpen = false

    /// `Counting/Compressing objects:` for push (server pack-building).
    /// Throttle by integer percent + emit the `, done.\n` terminator on
    /// every stage completion.
    var lastPackStage: Int32 = -1
    var lastPackPct: Int = -1

    /// `Writing objects:` for push (client pushes the pack).
    var lastPushTransferPct: Int = -1

    /// Suppress sideband / transfer / pack progress for local URLs.
    /// libgit2's local transport fires the callbacks even when real git
    /// stays silent — set this to mute them. Per-ref summary lines and
    /// header still emit.
    var suppressTransferProgress = false

    static let stderr = Shell.current.stderr

    static func write(_ s: String) {
        stderr.write(Data(s.utf8))
    }

    /// Emit the `From <url>\n` / `To <url>\n` header on first call.
    mutating func emitHeaderIfNeeded() {
        guard !headerEmitted, let url = headerURL else { return }
        headerEmitted = true
        let verb = direction == .fetch ? "From" : "To"
        Self.write("\(verb) \(url)\n")
    }

    /// True if `url` points at a local repo (file:// or a plain path
    /// with no scheme). libgit2's local transport fires transfer /
    /// sideband callbacks where real git stays silent, so we mute them
    /// for these URLs to match real-git's local-clone/fetch output.
    static func isLocalURL(_ url: String?) -> Bool {
        guard let url else { return false }
        if url.hasPrefix("file://") { return true }
        // Schemed remote (http://, https://, ssh://, git@host:…) is
        // never local. Bare paths (no `://` and either absolute or
        // present on disk) are.
        if url.contains("://") { return false }
        if url.contains("@") && url.contains(":") { return false } // ssh shorthand
        if url.hasPrefix("/") { return true }
        return FileManager.default.fileExists(atPath: url)
    }

    /// Flush any pending per-ref summary lines. Caller invokes this
    /// after the network op completes.
    mutating func flushRefLines() {
        guard !refLines.isEmpty else { return }
        emitHeaderIfNeeded()
        for line in refLines {
            Self.write(line + "\n")
        }
        refLines.removeAll(keepingCapacity: false)
    }
}
