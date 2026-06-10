import Foundation

/// Palette used by `git status` / `git diff` to colorize their
/// output. Mirrors real git's defaults (`color.status.*` /
/// `color.diff.*`) close enough to look familiar without
/// implementing config-driven theming.
///
/// When `enabled == false`, every method returns its input
/// unchanged — call sites stay terse (`palette.staged("modified:")`
/// works whether color is on or off).
public struct ColorPalette: Sendable {

    public let enabled: Bool
    public init(enabled: Bool) { self.enabled = enabled }

    /// No-op palette — every method returns its input unchanged.
    /// Default for `verboseFormat()` so existing callers (and the
    /// `--color=never` path) need no extra plumbing.
    public static let disabled = ColorPalette(enabled: false)

    // MARK: - status

    /// Staged paths / verbose labels — `new file:`, `modified:`, etc.
    public func staged(_ s: String)    -> String { wrap(s, sgr: "32") }    // green
    /// Unstaged paths + untracked paths + conflicted lines.
    public func unstaged(_ s: String)  -> String { wrap(s, sgr: "31") }    // red
    /// Branch name in the verbose header.
    public func branch(_ s: String)    -> String { wrap(s, sgr: "32") }    // green

    // MARK: - diff

    /// Bold-white file headers (`diff --git`, `index`, `--- a/foo`,
    /// `+++ b/foo`).
    public func meta(_ s: String)      -> String { wrap(s, sgr: "1") }     // bold
    /// `@@ … @@` hunk separators.
    public func frag(_ s: String)      -> String { wrap(s, sgr: "36") }    // cyan
    /// `+` lines.
    public func added(_ s: String)     -> String { wrap(s, sgr: "32") }    // green
    /// `-` lines.
    public func removed(_ s: String)   -> String { wrap(s, sgr: "31") }    // red

    private func wrap(_ s: String, sgr: String) -> String {
        guard enabled, !s.isEmpty else { return s }
        return "\u{1B}[\(sgr)m\(s)\u{1B}[m"
    }

    // MARK: - patch colorizer

    /// Walk a libgit2-produced unified-diff string line by line and
    /// apply the standard `git diff` colors. Same per-line rules real
    /// git uses for `color.diff.*`:
    ///   - `diff --git` / `index` / `--- a/...` / `+++ b/...` → bold
    ///   - `@@ … @@`                                          → cyan
    ///   - leading `+` (but not the `+++` header)             → green
    ///   - leading `-` (but not the `---` header)             → red
    ///   - everything else                                    → default
    ///
    /// No-op when `enabled == false`. Preserves the input's trailing
    /// newline policy byte-for-byte.
    public func colorizePatch(_ patch: String) -> String {
        guard enabled, !patch.isEmpty else { return patch }
        let hadTrailingNewline = patch.hasSuffix("\n")
        var lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // `split` with `omittingEmptySubsequences: false` keeps the
        // empty tail after a trailing newline. Drop it so we don't
        // emit an extra blank line, then re-add the newline below.
        if hadTrailingNewline, lines.last == "" { lines.removeLast() }
        for (i, line) in lines.enumerated() {
            lines[i] = colorize(diffLine: line)
        }
        return lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    private func colorize(diffLine line: String) -> String {
        if line.hasPrefix("diff --git") || line.hasPrefix("index ")
            || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
            || line.hasPrefix("similarity index") || line.hasPrefix("rename from")
            || line.hasPrefix("rename to") || line.hasPrefix("copy from")
            || line.hasPrefix("copy to") || line.hasPrefix("old mode")
            || line.hasPrefix("new mode") {
            return meta(line)
        }
        if line.hasPrefix("@@") { return frag(line) }
        if line.hasPrefix("+")  { return added(line) }
        if line.hasPrefix("-")  { return removed(line) }
        return line
    }
}
