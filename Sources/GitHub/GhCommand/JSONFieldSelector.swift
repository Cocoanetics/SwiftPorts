import ArgumentParser
import Sandbox
import Foundation

/// Shared `--json <fields>` plumbing for subcommands that mirror upstream
/// `gh`'s field-selection JSON output.
///
/// Behaviour matches upstream byte-for-byte:
///   * Bare `--json` (rewritten by `GhCommand.main()` to `--json ""`)
///     prints "Specify one or more comma-separated fields for `--json`:"
///     followed by the alphabetised field list on stderr, exit code 1.
///   * Unknown field names print
///     `Unknown JSON field: "X"\nAvailable fields:\n  ...` on stderr,
///     exit code 1.
///   * Output is compact JSON with sorted keys, matching Go's
///     `encoding/json` ordering.
///
/// Each migrated command supplies a `[String: @Sendable (Resource) -> Any?]`
/// mapping gh's camelCase field names to a value-extractor. Date values
/// must be pre-converted with ``iso8601(_:)``; URLs to strings.
public enum JSONFieldSelector {
    /// Parse the comma-separated field list. Throws ``ExitCode(1)`` after
    /// printing the upstream-matching diagnostic if `raw` is empty
    /// (bare `--json`) or contains an unknown field name.
    public static func parse<Resource>(
        raw: String,
        fieldMap: [String: @Sendable (Resource) -> Any?]
    ) throws -> [String] {
        if raw.isEmpty {
            printAvailableFields(fieldMap)
            throw ExitCode(1)
        }
        let fields = raw.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        if let unknown = fields.first(where: { fieldMap[$0] == nil }) {
            printUnknownField(unknown, fieldMap: fieldMap)
            throw ExitCode(1)
        }
        return fields
    }

    /// Render an array of resources to a compact JSON array string.
    public static func render<Resource>(
        items: [Resource],
        fields: [String],
        fieldMap: [String: @Sendable (Resource) -> Any?]
    ) throws -> String {
        let projected = items.map { project($0, fields: fields, fieldMap: fieldMap) }
        return try compactJSON(projected)
    }

    /// Render a single resource to a compact JSON object string.
    public static func render<Resource>(
        item: Resource,
        fields: [String],
        fieldMap: [String: @Sendable (Resource) -> Any?]
    ) throws -> String {
        let projected = project(item, fields: fields, fieldMap: fieldMap)
        return try compactJSON(projected)
    }

    /// ISO 8601 date formatter matching upstream gh output:
    /// `2026-05-05T08:50:24Z` (no fractional seconds).
    public static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func project<Resource>(
        _ resource: Resource,
        fields: [String],
        fieldMap: [String: @Sendable (Resource) -> Any?]
    ) -> [String: Any] {
        var dict: [String: Any] = [:]
        for field in fields {
            if let provider = fieldMap[field], let value = provider(resource) {
                dict[field] = value
            } else {
                dict[field] = NSNull()
            }
        }
        return dict
    }

    private static func compactJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func printAvailableFields<Resource>(
        _ fieldMap: [String: @Sendable (Resource) -> Any?]
    ) {
        let body = "Specify one or more comma-separated fields for `--json`:\n  "
            + fieldMap.keys.sorted().joined(separator: "\n  ")
            + "\n"
        Stdio.stderr.write(Data(body.utf8))
    }

    private static func printUnknownField<Resource>(
        _ field: String,
        fieldMap: [String: @Sendable (Resource) -> Any?]
    ) {
        let body = "Unknown JSON field: \"\(field)\"\nAvailable fields:\n  "
            + fieldMap.keys.sorted().joined(separator: "\n  ")
            + "\n"
        Stdio.stderr.write(Data(body.utf8))
    }
}
