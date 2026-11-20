import Foundation

/// The fields and order of `commands/command_ls_files.go`'s `lsFilesObject`.
struct LsFilesObject: Codable {
    let name: String
    let size: Int64
    let checkout: Bool
    let downloaded: Bool
    let oidType: String
    let oid: String
    let version: String

    enum CodingKeys: String, CodingKey {
        case name, size, checkout, downloaded
        case oidType = "oid_type"
        case oid, version
    }

    var json: String {
        "  {\n   \"name\": \(Self.jsonString(name)),\n   \"size\": \(size),\n"
            + "   \"checkout\": \(checkout),\n   \"downloaded\": \(downloaded),\n"
            + "   \"oid_type\": \(Self.jsonString(oidType)),\n   \"oid\": \(Self.jsonString(oid)),\n"
            + "   \"version\": \(Self.jsonString(version))\n  }"
    }

    private static func jsonString(_ value: String) -> String {
        // Go's JSON HTML escaping, including the two Unicode line separators.
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
