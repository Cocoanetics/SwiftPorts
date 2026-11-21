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
            return isRemoteMeterLine(text.dropFirst(sidebandPrefix.count)) ? .remoteProgress : .message
        }
        guard meterPrefixes.contains(where: text.hasPrefix) else { return .message }
        if text.contains(", done.\n") { return .phaseComplete }
        return text.hasSuffix("\r") ? .update : .message
    }

    /// Whether `body`, a `remote:` line without its prefix, is a line of
    /// git's progress meter (`progress.c`): a phase's title, then a count
    /// or `<pct>% (<n>/<total>)`, then nothing but `, …` (`, done.`, the
    /// throughput) and padding. A hook's `Checking objects: denied` isn't.
    static func isRemoteMeterLine(_ body: Substring) -> Bool {
        guard let title = remoteMeterPrefixes.first(where: body.hasPrefix) else { return false }
        var rest = body.dropFirst(title.count)
        while let last = rest.last, last == "\r" || last == "\n" || last == " " { rest = rest.dropLast() }
        func digits() -> Bool {
            let count = rest.prefix(while: { $0.isASCII && $0.isNumber }).count
            rest = rest.dropFirst(count)
            return count > 0
        }
        guard rest.first == " " else { return false }
        rest = rest.drop { $0 == " " }
        guard digits() else { return false }
        if rest.hasPrefix("% (") {
            rest = rest.dropFirst(3)
            guard digits(), rest.first == "/" else { return false }
            rest = rest.dropFirst()
            guard digits(), rest.first == ")" else { return false }
            rest = rest.dropFirst()
        }
        return rest.isEmpty || rest.first == ","
    }

    /// Whether a record of `kind` is written.
    func keeps(_ kind: Record) -> Bool {
        switch kind {
        case .update, .phaseComplete: meter
        case .remoteProgress: meter && messages
        case .message: messages
        }
    }

    /// A writer for GitKit's callback that hands `write` what this policy
    /// keeps, unchanged. ``Writer/flush()`` it once the push is done.
    func sink(writing write: @escaping @Sendable (String) -> Void) -> Writer {
        Writer(policy: self, write: write)
    }

    /// Applies the policy to GitKit's records, which continue a `remote:`
    /// line split across sideband packets without the prefix. A
    /// continuation goes with its line; and when only the remote's meter
    /// is dropped, a split line is held until it ends, since its first
    /// part (`remote: Resolving`) can't tell meter from message.
    final class Writer: @unchecked Sendable {
        private let policy: PushProgressSink
        private let output: @Sendable (String) -> Void
        private let lock = NSLock()
        /// What the unterminated `remote:` line is, once decided.
        private var open: Record?
        /// The unterminated `remote:` line's parts, while undecided.
        private var pending: [String] = []

        init(policy: PushProgressSink, write: @escaping @Sendable (String) -> Void) {
            self.policy = policy
            output = write
        }

        /// Whether a line's kind changes what is written: only with
        /// messages on and the remote's meter off.
        private var holdsLines: Bool { policy.messages && !policy.meter }

        func write(_ text: String) {
            lock.withLock {
                let kind = PushProgressSink.classify(text)
                let sideband = text.hasPrefix(PushProgressSink.sidebandPrefix)
                let ends = text.hasSuffix("\r") || text.hasSuffix("\n")
                let continues = (open != nil || !pending.isEmpty) && !sideband && kind == .message
                if continues, !pending.isEmpty {
                    pending.append(text)
                    if ends { release() }
                } else if continues, let line = open {
                    emit(text, as: line)
                    if ends { open = nil }
                } else if sideband {
                    release()
                    open = nil
                    if ends {
                        emit(text, as: kind)
                    } else if holdsLines {
                        pending = [text]
                    } else {
                        open = kind
                        emit(text, as: kind)
                    }
                } else {
                    emit(text, as: kind)
                }
            }
        }

        /// Write a line still held when the push ends.
        func flush() {
            lock.withLock { release() }
        }

        private func release() {
            guard !pending.isEmpty else { return }
            let parts = pending
            pending = []
            let kind = PushProgressSink.classify(parts.joined())
            parts.forEach { emit($0, as: kind) }
        }

        private func emit(_ text: String, as kind: Record) {
            if policy.keeps(kind) { output(text) }
        }
    }
}
