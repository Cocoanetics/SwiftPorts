import Foundation
import RipgrepKit
import ShellKit

/// Writes one matched entry per call. Encapsulates the (small) display
/// transformations fd performs on the path before writing it.
struct Printer {

    let options: PrinterOptions
    private let lsColors: LsColors
    private let matcher: PatternMatcher?

    init(options: PrinterOptions, matcher: PatternMatcher? = nil) {
        self.options = options
        // Resolve LS_COLORS once at construction. Calling
        // `LsColors.fromEnvironment` per entry would re-parse the env
        // var on every match — wasteful when a run produces thousands
        // of entries.
        self.lsColors = options.lsColors ?? LsColors.fromEnvironment()
        self.matcher = matcher
    }

    /// Render and emit `entry`. The metadata snapshot drives
    /// directory-slash decoration and the LS_COLORS-driven palette.
    func emit(_ entry: Walker.Entry,
              metadata: EntryFilter.Metadata,
              to stdout: OutputSink) {
        if options.quiet { return }

        var path = path(for: entry)

        if options.directorySlash && metadata.isDirectory && !path.hasSuffix("/") {
            path += "/"
        }

        if options.color {
            path = colorize(path: path,
                            basename: entry.url.lastPathComponent,
                            metadata: metadata)
        }

        // Path-separator substitution runs *after* colorize so the
        // basename-slicing in `highlightRange` can hardcode `/`, and
        // so the SGR escapes (which never contain `/`) pass through
        // the substitution untouched.
        if let sep = options.pathSeparator, sep != "/" {
            path = path.replacingOccurrences(of: "/", with: sep)
        }

        let terminator: Character = options.print0 ? "\0" : "\n"
        stdout.write(path + String(terminator))
    }

    /// Build the user-facing path string. By default we use the
    /// walker's `displayPath` (carries the literal shape the user
    /// typed); `--absolute-path` and `--strip-cwd-prefix` override.
    private func path(for entry: Walker.Entry) -> String {
        if options.absolutePath {
            // `entry.url` is the I/O-facing URL — under a path-mapped
            // sandbox that's the translated HOST path. Fold it back
            // to the script-visible spelling before printing so the
            // embedder's host layout doesn't leak (a no-op without a
            // mapping).
            return Shell.displayPath(
                for: entry.url.standardizedFileURL.path)
        }
        var p = entry.displayPath
        if options.stripCwdPrefix && p.hasPrefix("./") {
            p = String(p.dropFirst(2))
        }
        return p
    }

    /// Apply the resolved LS_COLORS-style palette to the path, and
    /// overlay match highlighting on the pattern's hit when one is
    /// available. Returns the input unchanged when neither layer
    /// applies — matches what real fd / ls do for entries that fall
    /// through to the default style.
    ///
    /// Honors the same kill switches as ripgrep (`NO_COLOR` is
    /// checked at the CLI layer; this method only runs when
    /// `options.color` is already true).
    private func colorize(path: String,
                          basename: String,
                          metadata: EntryFilter.Metadata) -> String {
        let baseCode = lsColors.code(
            forBasename: basename,
            isDirectory: metadata.isDirectory,
            isSymlink: metadata.isSymlink,
            isRegularFile: metadata.isRegularFile,
            posixPermissions: metadata.posixPermissions,
            fileType: metadata.fileType)

        let highlightCode = options.matchHighlight
        let highlightRange: Range<String.Index>?
        if let highlightCode, !highlightCode.isEmpty, let matcher {
            highlightRange = matcher.highlightRange(in: path)
        } else {
            highlightRange = nil
        }

        // Fast path: nothing to draw.
        if baseCode == nil && highlightRange == nil {
            return path
        }

        // Base-only path: no highlight to overlay.
        guard let highlightCode, let highlightRange else {
            return baseCode.map { lsColors.wrap(path, with: $0) } ?? path
        }

        // Slice path into pre / matched / post and apply base + highlight.
        let pre = path[..<highlightRange.lowerBound]
        let matched = path[highlightRange]
        let post = path[highlightRange.upperBound...]
        let reset = lsColors.resetEscape

        var out = ""
        if let baseCode {
            if !pre.isEmpty {
                out += "\u{1B}[\(baseCode)m" + pre + reset
            }
            out += "\u{1B}[\(highlightCode)m" + matched + reset
            if !post.isEmpty {
                out += "\u{1B}[\(baseCode)m" + post + reset
            }
        } else {
            out += pre
            out += "\u{1B}[\(highlightCode)m" + matched + reset
            out += post
        }
        return out
    }
}
