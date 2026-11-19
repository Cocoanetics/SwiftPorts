import Foundation

extension TrackOptions {
    func listing(_ known: [AttributePath]) -> LFSCommandResult {
        if json {
            // Field order and the single-space indentation are Go's json.Encoder output.
            let rows = known.map { entry in
                "  {\n   \"pattern\": \(Self.jsonString(entry.pattern)),\n"
                    + "   \"source\": \(Self.jsonString(entry.source)),\n"
                    + "   \"lockable\": \(entry.lockable),\n   \"tracked\": \(entry.tracked)\n  }"
            }
            let array = rows.isEmpty ? "[]" : "[\n" + rows.joined(separator: ",\n") + "\n ]"
            return LFSCommandResult(stdout: "{\n \"patterns\": \(array)\n}\n")
        }
        if known.isEmpty { return LFSCommandResult() }
        var text = "Listing tracked patterns\n"
        for entry in known where entry.tracked || entry.lockable {
            text += "    \(entry.pattern)\(entry.lockable ? " [lockable]" : "") (\(entry.source))\n"
        }
        if !noExcluded {
            text += "Listing excluded patterns\n"
            for entry in known where !entry.tracked && !entry.lockable {
                text += "    \(entry.pattern) (\(entry.source))\n"
            }
        }
        return LFSCommandResult(stdout: text)
    }

    private static func jsonString(_ value: String) -> String {
        // Go additionally escapes the HTML-sensitive characters and Unicode line separators.
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
