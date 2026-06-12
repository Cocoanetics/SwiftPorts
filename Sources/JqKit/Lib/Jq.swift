import Foundation

/// In-process jq engine — parses a jq filter, evaluates it against
/// JSON input, and returns the results.
///
/// The engine is a recursive-descent parser plus a streaming
/// evaluator with the standard builtin library. It runs anywhere
/// Foundation runs (macOS / iOS / tvOS / watchOS / visionOS / Linux
/// / Windows / Android) — no system C dependency, no subprocess.
///
/// `eval` and `evalString` cover the common "filter a response body"
/// case. Use ``parseFilter(_:)`` + ``evaluate(_:on:)`` when you want
/// to amortize parsing across many inputs.
public enum Jq {

    /// Apply `filter` to `json` and return the formatted result.
    ///
    /// Each value in the output stream is printed on its own line.
    /// Strings are JSON-encoded (with quotes). Use ``evalString(filter:on:)``
    /// for `-r` / raw-string semantics where strings come back unquoted.
    public static func eval(filter: String, on json: Data) throws -> Data {
        let results = try evalValues(filter: filter, on: json)
        var out = ""
        for v in results {
            out += JqFormatter.format(v)
            out += "\n"
        }
        return Data(out.utf8)
    }

    /// Apply `filter` to `json` and return raw string results — one
    /// per output value, the way `gh api --jq` prints them. Strings
    /// are unquoted (jq's `-r` mode); everything else is compact
    /// single-line JSON with object keys sorted recursively, matching
    /// the gojq engine upstream gh embeds (gojq does not preserve
    /// object key order — it sorts on output).
    public static func evalString(filter: String, on json: Data) throws -> [String] {
        let results = try evalValues(filter: filter, on: json)
        let opts = JqFormatter.Options(compact: true, raw: true, sortKeys: true)
        return results.map { JqFormatter.format($0, options: opts) }
    }

    /// Parse a jq filter source into an AST. Reuse the result across
    /// calls to ``evaluate(_:on:)`` to avoid re-parsing.
    public static func parseFilter(_ filter: String) throws -> JqAST {
        try JqParser.parse(filter)
    }

    /// Evaluate a pre-parsed filter against a single JSON value.
    public static func evaluate(_ filter: JqAST, on value: JqValue) throws -> [JqValue] {
        try JqEvaluator.evaluate(value, filter, ctx: JqContext())
    }

    /// Apply `filter` to `json` and return the result as JqValues.
    public static func evalValues(filter: String, on json: Data) throws -> [JqValue] {
        let ast = try parseFilter(filter)
        let source = String(decoding: json, as: UTF8.self)
        let inputs: [JqValue]
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            inputs = [.null]
        } else {
            inputs = try JqJSON.parseStream(source)
        }
        var out: [JqValue] = []
        let ctx = JqContext()
        for input in inputs {
            let results = try JqEvaluator.evaluate(input, ast, ctx: ctx)
            out.append(contentsOf: results)
        }
        return out
    }
}
