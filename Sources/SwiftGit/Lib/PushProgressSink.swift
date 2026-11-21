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
        /// Anything else: `remote:` text or its continuation, the
        /// `To <url>` header, a ref line.
        case message
    }

    /// The phases GitKit's meter reports, as it labels them.
    static let meterPrefixes = [
        "Counting objects:", "Compressing objects:", "Writing objects:",
        "Receiving objects:", "Resolving deltas:"
    ]

    static func classify(_ text: String) -> Record {
        guard meterPrefixes.contains(where: text.hasPrefix) else { return .message }
        if text.contains(", done.\n") { return .phaseComplete }
        return text.hasSuffix("\r") ? .update : .message
    }

    /// Whether `text` is written.
    func keeps(_ text: String) -> Bool {
        Self.classify(text) == .message ? messages : meter
    }

    /// A callback for GitKit that hands `write` what this policy keeps,
    /// unchanged.
    func sink(writing write: @escaping @Sendable (String) -> Void) -> @Sendable (String) -> Void {
        if !meter && !messages { return { _ in } }
        return { [self] text in
            if keeps(text) { write(text) }
        }
    }
}
