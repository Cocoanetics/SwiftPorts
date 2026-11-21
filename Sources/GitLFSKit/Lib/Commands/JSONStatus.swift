import Foundation

struct JSONStatus: Codable {
    // Go strings compare by bytes; canonically equivalent Swift strings can name distinct paths.
    var files: [Data: JSONStatusEntry] = [:]

    func json() throws -> String {
        let entries = try files.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map { name, entry in
            var value = "\"status\":" + (try Self.quote(entry.status))
            if let from = entry.from, !from.isEmpty { value += ",\"from\":" + (try Self.quote(from)) }
            return try Self.quote(String(decoding: name, as: UTF8.self)) + ":{" + value + "}"
        }
        return "{\"files\":{" + entries.joined(separator: ",") + "}}"
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: FileKey.self)
        let entries = try container.nestedContainer(keyedBy: FileKey.self, forKey: FileKey(stringValue: "files"))
        for key in entries.allKeys {
            files[Data(key.stringValue.utf8)] = try entries.decode(JSONStatusEntry.self, forKey: key)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: FileKey.self)
        var entries = container.nestedContainer(keyedBy: FileKey.self, forKey: FileKey(stringValue: "files"))
        for (name, entry) in files {
            try entries.encode(entry, forKey: FileKey(stringValue: String(decoding: name, as: UTF8.self)))
        }
    }

    private struct FileKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func quote(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
