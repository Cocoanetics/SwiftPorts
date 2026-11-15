import Foundation

enum SSHArmor {
    static func encode(_ data: Data, label: String) -> String {
        let base64 = Array(data.base64EncodedString())
        let lines = stride(from: 0, to: base64.count, by: 70).map {
            String(base64[$0..<min($0 + 70, base64.count)])
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    static func decode(_ text: String, label: String) throws -> Data {
        let begin = "-----BEGIN \(label)-----\n", end = "-----END \(label)-----"
        guard text.hasPrefix(begin), let range = text.range(of: end),
              let data = Data(base64Encoded: text[begin.endIndex..<range.lowerBound]
                .filter { !$0.isWhitespace }) else {
            throw SSHKeygenError("invalid format")
        }
        return data
    }
}
