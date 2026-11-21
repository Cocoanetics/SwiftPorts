import Foundation

/// What `git push` writes to stderr, as git's `transport_set_verbosity`
/// decides it, applied to GitKit's untyped progress callback.
///
/// The meter (`Counting objects:` … `Writing objects:`) runs when
/// `--progress` says so, even with `-q` or without a terminal; never
/// with `--no-progress`; and otherwise only when not quiet and stderr is
/// a terminal. Everything else — `To <url>`, the ref lines, `remote:`
/// text — goes unless `-q`. Lines pass through as GitKit framed them:
/// a meter update ends in `\r`, a finished phase in `, done.\n`.
///
/// The remote's own meter (`remote: Resolving deltas: …`) goes only when
/// both do. git asks receive-pack for `quiet` whenever it is quiet or its
/// meter is off (`send-pack.c`), so the remote never sends it; libgit2
/// can't ask, so it is dropped here instead, hook output kept.
struct PushProgressSink {
    /// Whether the transfer meter is shown.
    let meter: Bool
    /// Whether the header, ref lines and `remote:` text are shown.
    let messages: Bool

    /// - Parameters:
    ///   - reportProgress: `--progress` (`true`) or `--no-progress`
    ///     (`false`), the last one given; `nil` for neither.
    ///   - quiet: `-q`.
    ///   - terminal: Whether stderr is a terminal.
    init(reportProgress: Bool?, quiet: Bool, terminal: Bool) {
        meter = reportProgress ?? (!quiet && terminal)
        messages = !quiet
    }

    /// One string GitKit hands the progress callback.
    enum Record: Equatable {
        /// A meter line still in its phase, ending in `\r`.
        case update
        /// A meter line finishing its phase (`, done.\n`).
        case phaseComplete
        /// A `remote:` line of receive-pack's meter.
        case remoteProgress
        /// Anything else: `remote:` text or its continuation, the
        /// `To <url>` header, a ref line.
        case message
    }

    /// The phases GitKit's meter reports, as it labels them.
    static let meterPrefixes = [
        "Counting objects:", "Compressing objects:", "Writing objects:",
        "Receiving objects:", "Resolving deltas:"
    ]

    /// The phases receive-pack's `unpack-objects` / `index-pack` report,
    /// which `quiet` turns off.
    static let remoteMeterPrefixes = [
        "Unpacking objects:", "Receiving objects:", "Indexing objects:",
        "Resolving deltas:", "Checking objects:"
    ]

    static let sidebandPrefix = "remote: "

    static func classify(_ text: String) -> Record {
        if text.hasPrefix(sidebandPrefix) {
            let body = text.dropFirst(sidebandPrefix.count)
            return remoteMeterPrefixes.contains(where: body.hasPrefix) ? .remoteProgress : .message
        }
        guard meterPrefixes.contains(where: text.hasPrefix) else { return .message }
        if text.contains(", done.\n") { return .phaseComplete }
        return text.hasSuffix("\r") ? .update : .message
    }

    /// Whether a record of `kind` is written.
    func keeps(_ kind: Record) -> Bool {
        switch kind {
        case .update, .phaseComplete: meter
        case .remoteProgress: meter && messages
        case .message: messages
        }
    }

    /// A callback for GitKit that hands `write` what this policy keeps,
    /// unchanged. GitKit continues a `remote:` line split across sideband
    /// packets without the prefix; the continuation goes with its line.
    func sink(writing write: @escaping @Sendable (String) -> Void) -> @Sendable (String) -> Void {
        if !meter && !messages { return { _ in } }
        let line = OpenSidebandLine()
        return { [self] text in
            if keeps(line.kind(of: text)) { write(text) }
        }
    }

    /// The `remote:` line GitKit last left unterminated, if any.
    private final class OpenSidebandLine: @unchecked Sendable {
        private let lock = NSLock()
        private var open: Record?

        func kind(of text: String) -> Record {
            lock.withLock {
                var kind = PushProgressSink.classify(text)
                if let open, kind == .message, !text.hasPrefix(PushProgressSink.sidebandPrefix) {
                    kind = open
                } else if kind != .remoteProgress, !text.hasPrefix(PushProgressSink.sidebandPrefix) {
                    return kind
                }
                open = text.hasSuffix("\r") || text.hasSuffix("\n") ? nil : kind
                return kind
            }
        }
    }
}
